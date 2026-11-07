import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An A7R IV on the far end of PTP, for the self-test to drive the camera process with: its
/// settings start as the one on the copy stand listed them (`recorded`, read 2026-11-06 at f/4.5,
/// pixel shift on, 4 shots), and it answers as that one did: writes taken only with the computer's
/// priority and reported a read late, MF not on offer with the lens's switch at AF (and a write of
/// it taken and nothing done), the pixel shift switched by ControlDevice, pictures held for the
/// computer one by one at the transfer handle, a live view at its own; and for a second after a
/// group, its pixel-shift status still busy (0xD23C), and while the half-press is held, a switch
/// taken and nothing done with it.
///
/// `EPSCAN_PTP_SIM` sets it up: `absent=1` (no camera on the cable), `shift=1|4|16`,
/// `transfer=ms` (between pictures), `focus=afs|dmf|mf|lensmf`, `priority=0|1`.
final class SimulatedSonyBody: PTPTransport {
  var onEvent: ((UInt16, [UInt32]) -> Void)?
  var onGone: (() -> Void)?
  private let lock = NSLock()
  private var props: [UInt16: SonyWire.Descriptor]
  /// Writes made, shown from the read after next.
  private var pending = [(UInt16, Int64)]()
  private var waiting = [(name: String, data: Data)]()
  private var number = 4370
  private var halfPressed = false
  private let absent: Bool
  private let transfer: Double
  private lazy var liveFrame: Data = Self.frame()

  init(_ setup: String) {
    var o = [String: String]()
    for pair in setup.split(separator: ",") {
      let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
      if kv.count == 2 { o[kv[0]] = kv[1] }
    }
    absent = o["absent"] == "1"
    transfer = Double(o["transfer"] ?? "300").map { $0 / 1000 } ?? 0.3
    props = SonyWire.descriptors(Data(base64Encoded: Self.recorded.joined()) ?? Data())
    set(SonySettings.priority, Int64(o["priority"] ?? "0") ?? 0)
    switch o["shift"] {
    case "1": set(SonySettings.shiftOn, 0)
    case "16": set(SonySettings.shiftNumber, 16)
    default: break
    }
    switch o["focus"] {
    case "dmf": set(0x500A, 0x8006)
    case "mf": set(0x500A, 1)
    case "lensmf":
      props[0x500A]?.current = 1
      props[0x500A]?.values = [1]
      props[0x500A]?.enabled = 2
    default: break
    }
    offerFocusModes()
  }
  private func set(_ code: UInt16, _ v: Int64) { props[code]?.current = v }
  /// With the pixel shift on, the camera offers no AF-C or AF-A.
  private func offerFocusModes() {
    guard props[0x500A]?.enabled == 1 else { return }
    let shifting = props[SonySettings.shiftOn]?.current == 1
    props[0x500A]?.values = shifting ? [2, 0x8006] : [2, 0x8005, 0x8004, 0x8006]
  }
  private var priority: Bool { props[SonySettings.priority]?.current == 1 }
  private func stage(_ code: UInt16, _ v: Int64) { pending.append((code, v)) }

  func open(timeout: TimeInterval) throws -> String {
    Thread.sleep(forTimeInterval: 0.2)
    if absent { throw PTPFailure.noCamera }
    return "ILCE-7RM4"
  }
  func close() {}
  func transact(_ op: UInt16, _ params: [UInt32], out: Data?, timeout: TimeInterval) throws -> (data: Data, code: UInt16) {
    lock.lock()
    defer { lock.unlock() }
    let ok = SonyWire.ok
    let code = params.first.map { UInt16(truncatingIfNeeded: $0) } ?? 0
    func sent(_ type: UInt16) -> Int64 { out.map { SonyWire.value($0, 0, type) } ?? 0 }
    switch op {
    case SonyWire.sdioConnect: return (Data(), ok)
    case SonyWire.extDeviceInfo: return (Data([0x2C, 0x01, 0, 0, 0, 0]), ok)
    case SonyWire.allProps:
      let d = SonyWire.encode(Array(props.values))
      for (c, v) in pending { props[c]?.current = v }
      if !pending.isEmpty { offerFocusModes() }
      pending.removeAll()
      return (d, ok)
    case SonyWire.setProp:
      guard let p = props[code] else { return (Data(), 0x2005) }
      let v = sent(p.type)
      if code == SonySettings.priority {
        props[code]?.current = v
      } else if priority, p.writable {
        // MF is not taken where it is not on offer (the lens's switch at AF).
        if code == 0x500A, !p.values.contains(v) { return (Data(), ok) }
        stage(code, v)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self.onEvent?(SonyWire.propertyChanged, [UInt32(code)]) }
      }
      return (Data(), ok)
    case SonyWire.control:
      let v = sent(code == 0xD2DC ? 6 : code == 0xD2D1 ? 3 : 4)
      guard priority else { return (Data(), ok) }
      switch code {
      case 0xD2C1:
        halfPressed = v == 2
        let mode = props[0x500A]?.current ?? 1
        if halfPressed, mode == 2 || mode == 0x8006 {
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            self.lock.lock()
            if self.halfPressed { self.props[0xD213]?.current = 2 }
            self.lock.unlock()
          }
        } else if !halfPressed {
          props[0xD213]?.current = 1
        }
      case 0xD2C2 where v == 2:
        let shots = SonySettings.shots(props) ?? 1
        if shots > 1 { props[SonySettings.shiftStatus]?.current = 1 }
        for i in 0..<shots {
          DispatchQueue.global().asyncAfter(deadline: .now() + transfer * Double(i + 1)) { self.picture() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + transfer * Double(shots) + 1) {
          self.lock.lock()
          self.props[SonySettings.shiftStatus]?.current = 0
          self.lock.unlock()
        }
      case SonySettings.shiftSwitch where props[SonySettings.shiftStatus]?.current != 1 && !halfPressed:
        stage(SonySettings.shiftOn, v == 2 ? 1 : 0)
      default: break
      }
      return (Data(), ok)
    case SonyWire.objectInfo:
      guard code == UInt16(truncatingIfNeeded: SonyWire.pictureHandle), let first = waiting.first else { return (Data(), 0x2009) }
      return (SonyWire.objectInfo(name: first.name, size: first.data.count), ok)
    case SonyWire.object:
      if params.first == SonyWire.liveHandle { return (liveFrame, ok) }
      guard !waiting.isEmpty else { return (Data(), 0x2009) }
      let first = waiting.removeFirst()
      props[SonySettings.objectsWaiting]?.current = waiting.isEmpty ? 0 : Int64(0x8000 + waiting.count)
      return (first.data, ok)
    default:
      return (Data(), 0x2005)
    }
  }
  /// A picture written and held for the computer: an ARW's first bytes and some more.
  private func picture() {
    lock.lock()
    number += 1
    var data = Data("II*\u{0}".utf8)
    data.append(Data(repeating: UInt8(number & 0xFF), count: 4092))
    waiting.append((String(format: "DSC%05d.ARW", number), data))
    props[SonySettings.objectsWaiting]?.current = Int64(0x8000 + waiting.count)
    lock.unlock()
    onEvent?(SonyWire.objectAdded, [SonyWire.pictureHandle])
  }
  /// A live-view frame as Sony's: the JPEG's offset and size, then the JPEG.
  private static func frame() -> Data {
    let w = 64, h = 48
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<w {
      ctx.setFillColor(red: CGFloat(x) / CGFloat(w), green: 0.5, blue: 0.4, alpha: 1)
      ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
    }
    let jpeg = NSMutableData()
    if let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil), let image = ctx.makeImage() {
      CGImageDestinationAddImage(dest, image, nil)
      CGImageDestinationFinalize(dest)
    }
    var d = Data()
    func le32(_ v: Int) { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    le32(16)
    le32(jpeg.length)
    d.append(Data(count: 8))
    d.append(jpeg as Data)
    return d
  }

  /// GetAllExtDevicePropInfo as the A7R IV answered it on 2026-11-06 (protocol 300, AF-S, f/4.5,
  /// 1/125, ISO 100, colour temperature 5500K, pixel shift on with 4 shots, the computer's priority).
  static let recorded = [
    "WgAAAAAAAAAFUAQAAQEAABKAAg8AAgAEABGAEIAGAAGAAoADgASABwAwgBKAIIAhgCKADwACAAQAEYAQgAYAAYACgAOABIAHADCAEoAggCGAIoAHUAQA",
    "AQH//8IBAhMAGAFAAV4BkAHCAfQBMAJ2AsYCIAOEA+gDTAQUBXgFQAYIB9AHmAgTABgBQAFeAZABwgH0ATACdgLGAiADhAPoA0wEFAV4BUAGCAfQB5gI",
    "ClAEAAEBAAACAAICAAIABoAFAAIABYAEgAaAAQALUAQAAQEAAAGAAgYAAYACgASABYADgAaABgABgAKABIAFgAOABoAMUAQAAQEAAAMAAgMAAwABgAOA",
    "BQACAAEAAwABgAOADlAGAAEBAAAAAAEAAAACDQACAAEAAwACAAQAAwABAAAAUIAHAFGABwBSgAcAU4AHAFmACQBagAkAW4AJAFyACQAAgAQADQACAAEA",
    "AwACAAQAAwABAAAAUIAHAFGABwBSgAcAU4AHAFmACQBagAkAW4AJAFyACQAAgAQAEFADAAECAAAAAAIAAB8AiBNcEswQoA90DuQMuAuMCvwI0AekBhQF",
    "6AO8AiwBAADU/kT9GPzs+lz5MPgE93T1SPQc84zxYPA076TteOwTUAYAAQEAAAAAAQAAAAIEAAEAAAAEgAMAA4ADAAWAAwAyAAEAAAASgAEAFYABAAIA",
    "AQAQgAEABIADAAOAAwAFgAMACIAIAAmACAAMgAgADYAIAA6ACAAPgAgAN4MEADeFBAA3iQQAV4MEAFeFBABXiQQAd4MEAHeFBAB3iQQAEYMEABGFBAAR",
    "iQQAIYMEACGFBAAxgwQAMYUEADaDBQA2hQUANokFAFaDBQBWhQUAVokFAHaDBQB2hQUAdokFABCDBQAQhQUAEIkFACCDBQAghQUAMIMFADCFBQAogAYA",
    "GIAGACmABwAZgAcAANIDAAEBAAAAAAITALgLjAr8CNAHpAYUBegDvAIsAQAA1P5E/Rj87Ppc+TD4BPd09Uj0EwC4C4wK/AjQB6QGFAXoA7wCLAEAANT+",
    "RP0Y/Oz6XPkw+AT3dPVI9AHSAgABAQABAgcAAR8REhMUFQcAAR8REhMUFQPSAgABAQABAgMAAQIDAwABAgMN0gYAAQH/////fQABAAI3AAoALAEKAPoA",
    "CgDIAAoAlgAKAIIACgBkAAoAUAAKADwACgAyAAoAKAAKACAACgAZAAoAFAAKABAACgANAAoACgAKAAgACgAGAAoABQAKAAQAAwABAAQAAQAFAAEABgAB",
    "AAgAAQAKAAEADQABAA8AAQAUAAEAGQABAB4AAQAoAAEAMgABADwAAQBQAAEAZAABAH0AAQCgAAEAyAABAPoAAQBAAQEAkAEBAPQBAQCAAgEAIAMBAOgD",
    "AQDiBAEAQAYBANAHAQDECQEAgAwBAKAPAQCIEwEAABkBAEAfAQA3AAoALAEKAPoACgDIAAoAlgAKAIIACgBkAAoAUAAKADwACgAyAAoAKAAKACAACgAZ",
    "AAoAFAAKABAACgANAAoACgAKAAgACgAGAAoABQAKAAQAAwABAAQAAQAFAAEABgABAAgAAQAKAAEADQABAA8AAQAUAAEAGQABAB4AAQAoAAEAMgABADwA",
    "AQBQAAEAZAABAH0AAQCgAAEAyAABAPoAAQBAAQEAkAEBAPQBAQCAAgEAIAMBAOgDAQDiBAEAQAYBANAHAQDECQEAgAwBAKAPAQCIEwEAABkBAEAfAQAO",
    "0gIAAAEADwIAAAAAD9IEAAEBAAB8FQHECawmZAAQ0gIAAQEAwAGk3AER0gIAAQEAAQIEAAEDAgQEAAEDAgQT0gIAAAEAAQIAAAAAFNIGAAAB/////wCk",
    "YAcBAAAAAP////8BAAAAFdIEAAABAAAAAAEAAP//AQAX0gIAAAEAAQIAAAAAGNIBAAACAGMB/2QBG9IEAAECAAAAgAIBAACAEAAAgAGAAoADgASABYAQ",
    "gCCAIYAwgECAUIBRgFKAU4BggBzSAgABAQDAAaTcAh3SAgAAAgAAAQACAR7SBgABAf///wBkAAAAAiAA////AGQAAAB9AAAAoAAAAMgAAAD6AAAAQAEA",
    "AJABAAD0AQAAgAIAACADAADoAwAA4gQAAEAGAADQBwAAxAkAAIAMAACgDwAAiBMAAAAZAABAHwAAECcAAAAyAACAPgAAIE4AAABkAAAAfQAAQJwAEADI",
    "ABAA+gAQgDgBEACQARAgAP///wBkAAAAfQAAAKAAAADIAAAA+gAAAEABAACQAQAA9AEAAIACAAAgAwAA6AMAAOIEAABABgAA0AcAAMQJAACADAAAoA8A",
    "AIgTAAAAGQAAQB8AABAnAAAAMgAAgD4AACBOAAAAZAAAAH0AAECcABAAyAAQAPoAEIA4ARAAkAEQH9ICAAABAAECAAAAACHSAgAAAQABAgAAAAAi0gQA",
    "AQEAAAEAAgMAAQARABAAAwABABEAEAAj0v//AQEAAAAq0gIAAAAAAQIAAAAALNIEAAEBAAADAAIHAAEAAgADAAEBAgEDAQQBDgABAAIAAwABAQIBAwEE",
    "AQECAgIDAgQCBQIGAgcCMdICAAEBAAECAgABAgIAAQI10gIAAAAAAAICAAABAgAAATbSAgAAAQABAgIAAAECAAABONICAAAAAAACAgAAAQIAAAE50gIA",
    "AAEAAQICAAEAAgABADrSBAABAQEABAACAwABAAQAEAADAAEABAAQADvSBAABAQAA//8CCQD//wEAAgADAAQABQAKAA8AHgAJAP//AQACAAMABAAFAAoA",
    "DwAeADzSAgAAAQAAAgAAAAA90gQAAAEBAAEAAgAAAAA+0gIAAQAAAAIAAAAAP9ICAAEBAAACCwAAAQIDBAUGBwgJCgsAAAECAwQFBgcICQpA0gIAAQEA",
    "DgITAAECAwQFBgcICQoLDA0ODxAREhMTAAECAwQFBgcICQoLDA0ODxAREhNB0gIAAQEACQIDAAgJAwMACAkDQtIEAAEBAAABAAIHAAEAGAACABoAAwAc",
    "AB4ABwABABgAAgAaAAMAHAAeAEPSBAABAAAAAQACAAAAAETSBAABAAAAAQACAAAAAEXSAgABAAABAgAAAABG0gIAAQAAAQIAAAAAR9ICAAEBAAACBAAA",
    "AQIDBAAAAQIDSNICAAAAAAICAAAAAEnSBgAAAAAAAAAAAAAAAQAAAAD/////AQAAAErSBgAAAAAAAAAAAAAAAQAAAAD/////AQAAAEzSAgAAAgBkAQAA",
    "AU7SBAAAAQAAAQACAAAAAE/SAgABAgABAgIAAQICAAECUNICAAABAAACAAAAAFHSAgAAAgAAAQACAVLSAgABAQABAgMAAQIDAwABAgNT0gIAAQIAAQIB",
    "AAEDAAECA1TSCAABAQAAAAAAAAAA8ABAAQAAAAACBAD/////AAAAAP////8KAAAA/////zsAAAD/////dwAAAAQA/////wAAAAD/////CgAAAP////87",
    "AAAA/////3cAAABV0gIAAQEAAwIFAAUEAwIBBQAFBAMCAVbSAgAAAAAEAgAAAABX0gYAAAAAAAAAAAAAAAEAAAAA/////wEAAABY0gYAAAAAAAAAAAAA",
    "AAEAAAAA/////wEAAABZ0gIAAQIAAQIAAAAAWtICAAEBAAECAgAAAQIAAAFb0gIAAAAAAAICAAABAgAAAVzSBgABAAAAAADoAwAAAegDAADoAwAAZAAA",
    "AF3SBgAAAAAAAAAAAAABAF/SAgABAgABAgAAAABg0gIAAAAAAQIAAAAAYdIGAAAAAAAAAAAAAAABAAAAAP////8BAAAAYtICAAEBAAACAgABAAIAAQBj",
    "0gIAAQEAAAICAAEAAgABAGTSAgAAAQAAAgAAAABn0gYAAAEAAAAAAAAAAAEAAAAA4AGAAgEAAABo0gIAAQIAAQIAAAAAadICAAECAAMCAAAAAGrSAgAB",
    "AQICAgIAAQICAAECa9IGAAAAAAAAAAAAAAABAAAAAAAAAAABAAAAbNIGAAAAAAAAAAAAAAABAAAAAAAAAAABAAAAbdICAAAAAAACAgAAAQIAAAFu0gIA",
    "AAAAAAICAAABAgAAAW/SAgAAAAAAAgIAAAECAAABcNICAAABAAACAAAAAHHSAgAAAQABAgIAAAECAAABctICAAABAAECAgAAAQIAAAFz0gIAAAEAAAIA",
    "AAAAeNL//wAAAAAA",
  ]
}
