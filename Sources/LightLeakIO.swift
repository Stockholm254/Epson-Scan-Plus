import CoreGraphics
import Foundation
import ImageIO
import simd
import Security
import UniformTypeIdentifiers

// MARK: - Pixels in and out

extension LeakImage {
  static let space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!

  /// `image` in Adobe RGB at 16 bits, encoded with the pure 563/256 gamma the engine decodes with.
  /// A 16-bit Adobe RGB image keeps its samples exactly. ColorSync bends the deep shadows when it
  /// converts into Adobe RGB (sRGB 10/255 becomes 3072 instead of 4695 of 65535), so sRGB and linear
  /// images are converted here by the exact matrix and curves; ColorSync only changes the sample
  /// format, within one colour space, which it does losslessly. Other colour spaces go through
  /// linear sRGB by ColorSync.
  init(_ image: CGImage) throws {
    let w = image.width, h = image.height
    guard w >= 2, h >= 2 else { throw DeskError.message("图像尺寸过小，请导入完整照片。") }
    if let samples = Self.samples(image) {
      self.init(width: w, height: h, data: samples)
      return
    }
    let name = image.colorSpace?.name as String?
    enum Encoding { case adobe, srgb, linear }
    let space: CGColorSpace, encoding: Encoding, source: CGImage
    func named(_ n: CFString...) -> Bool { n.contains { name == $0 as String } }
    if named(CGColorSpace.adobeRGB1998) {
      (space, encoding, source) = (Self.space, .adobe, image)
    } else if named(CGColorSpace.sRGB, CGColorSpace.extendedSRGB) {
      (space, encoding, source) = (image.colorSpace!, .srgb, image)
    } else if named(CGColorSpace.linearSRGB, CGColorSpace.extendedLinearSRGB) {
      (space, encoding, source) = (CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .linear, image)
    } else if image.colorSpace == nil || name?.contains("DeviceRGB") == true {
      // Untagged RGB is taken as sRGB, as FilmLightLab's image library takes it.
      let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
      (space, encoding, source) = (srgb, .srgb, image.copy(colorSpace: srgb) ?? image)
    } else {
      (space, encoding, source) = (CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .linear, image)
    }
    var floats = [Float](repeating: 0, count: w * h * 4)
    let drawn = floats.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      ctx.interpolationQuality = .none
      ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { throw DeskError.message("无法读取图像像素。") }
    switch encoding {
    case .adobe: self.init(width: w, height: h, data: Self.quantized(floats, w, h))
    case .srgb: self.init(width: w, height: h, data: Self.adobe(fromSRGB: floats, w, h, linear: false))
    case .linear: self.init(width: w, height: h, data: Self.adobe(fromSRGB: floats, w, h, linear: true))
    }
  }
  /// Linear sRGB to linear Adobe RGB (1998): both D65, the same red and blue primaries.
  static let fromSRGB: simd_double3x3 = {
    func matrix(_ primaries: [(Double, Double)]) -> simd_double3x3 {
      let white = SIMD3(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)
      let m = simd_double3x3(columns: (
        SIMD3(primaries[0].0 / primaries[0].1, 1, (1 - primaries[0].0 - primaries[0].1) / primaries[0].1),
        SIMD3(primaries[1].0 / primaries[1].1, 1, (1 - primaries[1].0 - primaries[1].1) / primaries[1].1),
        SIMD3(primaries[2].0 / primaries[2].1, 1, (1 - primaries[2].0 - primaries[2].1) / primaries[2].1)))
      let s = m.inverse * white
      return simd_double3x3(columns: (m.columns.0 * s.x, m.columns.1 * s.y, m.columns.2 * s.z))
    }
    let srgb = matrix([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)]), adobe = matrix([(0.64, 0.33), (0.21, 0.71), (0.15, 0.06)])
    return adobe.inverse * srgb
  }()
  private static func quantized(_ f: [Float], _ w: Int, _ h: Int) -> [UInt16] {
    eachPixel(w, h) { i in SIMD3(Double(f[i * 4]), Double(f[i * 4 + 1]), Double(f[i * 4 + 2])) }
  }
  private static func adobe(fromSRGB f: [Float], _ w: Int, _ h: Int, linear: Bool) -> [UInt16] {
    func decode(_ v: Double) -> Double {
      let a = abs(v), l = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
      return v < 0 ? -l : l
    }
    let m = fromSRGB, inverse = 1 / LeakEngine.gamma
    return eachPixel(w, h) { i in
      var p = SIMD3(Double(f[i * 4]), Double(f[i * 4 + 1]), Double(f[i * 4 + 2]))
      if !linear { p = SIMD3(decode(p.x), decode(p.y), decode(p.z)) }
      let q = m * p
      return SIMD3(pow(min(1, max(0, q.x)), inverse), pow(min(1, max(0, q.y)), inverse), pow(min(1, max(0, q.z)), inverse))
    }
  }
  /// 16-bit samples from encoded values 0–1, every row at once.
  private static func eachPixel(_ w: Int, _ h: Int, _ value: (Int) -> SIMD3<Double>) -> [UInt16] {
    var out = [UInt16](repeating: 0, count: w * h * 3)
    out.withUnsafeMutableBufferPointer { dst in
      let dst = dst
      DispatchQueue.concurrentPerform(iterations: h) { y in
        for x in 0..<w {
          let i = y * w + x, v = value(i)
          for c in 0..<3 { dst[i * 3 + c] = UInt16((min(1, max(0, v[c])) * 65535).rounded()) }
        }
      }
    }
    return out
  }
  /// The samples of an opaque 16-bit Adobe RGB image as they are stored, or nil for any other.
  private static func samples(_ image: CGImage) -> [UInt16]? {
    guard image.bitsPerComponent == 16, image.colorSpace?.name == CGColorSpace.adobeRGB1998,
      !image.bitmapInfo.contains(.floatComponents), let bytes = image.dataProvider?.data as Data?
    else { return nil }
    let channels = image.bitsPerPixel / 16
    let first: Int
    switch image.alphaInfo {
    case .none: first = 0
    case .noneSkipLast, .last, .premultipliedLast: first = 0
    case .noneSkipFirst, .first, .premultipliedFirst: first = 1
    default: return nil
    }
    guard channels == 3 || channels == 4, image.alphaInfo == .none ? channels == 3 : channels == 4 else { return nil }
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    let little = order == .byteOrder16Little
    guard little || order == .byteOrder16Big || order.rawValue == 0 else { return nil }
    let w = image.width, h = image.height, row = image.bytesPerRow
    guard bytes.count >= row * (h - 1) + w * channels * 2 else { return nil }
    var out = [UInt16](repeating: 0, count: w * h * 3)
    bytes.withUnsafeBytes { raw in
      for y in 0..<h {
        for x in 0..<w {
          let o = y * row + (x * channels + first) * 2
          for c in 0..<3 {
            let v = raw.loadUnaligned(fromByteOffset: o + c * 2, as: UInt16.self)
            out[(y * w + x) * 3 + c] = little ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
          }
        }
      }
    }
    return out
  }
  init(contentsOf url: URL) throws {
    try self.init(ImagePipeline.shared.load(url))
  }
  /// The pixels as a 48-bit Adobe RGB image, for showing and saving.
  func cgImage() -> CGImage {
    let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
    return CGImage(
      width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: Self.space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  }
  /// A 16-bit Adobe RGB TIFF, uncompressed, written whole or not at all.
  func saveTIFF(to url: URL, dpi: Int = 300) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tif")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try ImagePipeline.shared.saveTIFF(cgImage(), to: temporary, dpi: dpi)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }
  /// An sRGB JPEG, no larger than `maxDimension`, with no metadata but its colour profile.
  func jpeg(maxDimension: Int? = nil, quality: Double) throws -> (data: Data, width: Int, height: Int) {
    var image = self
    if let maxDimension, max(width, height) > maxDimension {
      let scale = Double(maxDimension) / Double(max(width, height))
      image = LeakEngine.resampled(self, Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }
    guard let srgb = ImagePipeline.shared.converted(image.cgImage(), to: CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: 8)
    else { throw DeskError.message("无法生成 JPEG。") }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw DeskError.message("无法生成 JPEG。")
    }
    CGImageDestinationAddImage(dest, srgb, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw DeskError.message("无法生成 JPEG。") }
    return (out as Data, image.width, image.height)
  }
}

// MARK: - Resizing

extension LeakEngine {
  /// `image` no wider than `width` (never enlarged), Lanczos-filtered, then blurred by a Gaussian
  /// of `blur` pixels, as FilmLightLab's image library sized its previews.
  static func resized(_ image: LeakImage, width: Int, blur sigma: Double = 0) -> LeakImage {
    var out = image
    if width < image.width {
      out = resampled(image, width, max(1, Int(jsRound(Double(image.height) * Double(width) / Double(image.width)))))
    }
    if sigma > 0 { out = gaussian(out, sigma: sigma) }
    return out
  }
  private static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
  private static func lanczos3(_ x: Double) -> Double {
    if x == 0 { return 1 }
    if abs(x) >= 3 { return 0 }
    let px = Double.pi * x
    return 3 * sin(px) * sin(px / 3) / (px * px)
  }
  /// For each output position, the input positions it reads and their weights.
  private static func taps(from n: Int, to m: Int) -> [(index: [Int], weight: [Float])] {
    let scale = Double(n) / Double(m), filter = max(1, scale), support = 3 * filter
    return (0..<m).map { o in
      let center = (Double(o) + 0.5) * scale - 0.5
      var index = [Int](), weight = [Double]()
      for i in Int((center - support).rounded(.up))...Int((center + support).rounded(.down)) {
        let w = lanczos3((Double(i) - center) / filter)
        if w == 0 { continue }
        index.append(min(n - 1, max(0, i)))
        weight.append(w)
      }
      let sum = weight.reduce(0, +)
      return (index, weight.map { Float($0 / sum) })
    }
  }
  static func resampled(_ image: LeakImage, _ width: Int, _ height: Int) -> LeakImage {
    let w = image.width, h = image.height
    let across = taps(from: w, to: width), down = taps(from: h, to: height)
    var rows = [Float](repeating: 0, count: h * width * 3)
    image.data.withUnsafeBufferPointer { src in
      rows.withUnsafeMutableBufferPointer { dst in
        let dst = dst
        DispatchQueue.concurrentPerform(iterations: h) { y in
          for x in 0..<width {
            var sum = SIMD3<Float>(repeating: 0)
            let t = across[x]
            for k in 0..<t.index.count {
              let s = (y * w + t.index[k]) * 3
              sum += t.weight[k] * SIMD3(Float(src[s]), Float(src[s + 1]), Float(src[s + 2]))
            }
            let d = (y * width + x) * 3
            dst[d] = sum.x; dst[d + 1] = sum.y; dst[d + 2] = sum.z
          }
        }
      }
    }
    var out = [UInt16](repeating: 0, count: width * height * 3)
    rows.withUnsafeBufferPointer { src in
      out.withUnsafeMutableBufferPointer { dst in
        let dst = dst
        DispatchQueue.concurrentPerform(iterations: height) { y in
          let t = down[y]
          for x in 0..<width {
            var sum = SIMD3<Float>(repeating: 0)
            for k in 0..<t.index.count {
              let s = (t.index[k] * width + x) * 3
              sum += t.weight[k] * SIMD3(src[s], src[s + 1], src[s + 2])
            }
            let d = (y * width + x) * 3
            for c in 0..<3 { dst[d + c] = UInt16(min(65535, max(0, sum[c].rounded()))) }
          }
        }
      }
    }
    return LeakImage(width: width, height: height, data: out)
  }
  /// libvips's Gaussian at integer precision: a mask cut where it falls below a fifth of its peak,
  /// its values rounded to twentieths, applied across then down with edges repeated.
  static func gaussian(_ image: LeakImage, sigma: Double) -> LeakImage {
    var mask = [Int]()
    var x = 0
    while Double(x) < 8 * sigma {
      let v = exp(-Double(x * x) / (2 * sigma * sigma))
      if v < 0.2 { break }
      mask.append(Int((20 * v).rounded(.toNearestOrEven)))
      x += 1
    }
    let r = mask.count - 1, kernel = mask.reversed() + mask.dropFirst(), scale = kernel.reduce(0, +)
    let w = image.width, h = image.height
    func pass(_ src: [UInt16], across: Bool) -> [UInt16] {
      var out = [UInt16](repeating: 0, count: src.count)
      src.withUnsafeBufferPointer { s in
        out.withUnsafeMutableBufferPointer { d in
          let d = d
          DispatchQueue.concurrentPerform(iterations: h) { y in
            for x in 0..<w {
              var sum = SIMD3<Int>(repeating: 0)
              for k in -r...r {
                let i = across ? y * w + min(w - 1, max(0, x + k)) : min(h - 1, max(0, y + k)) * w + x
                sum &+= kernel[k + r] &* SIMD3(Int(s[i * 3]), Int(s[i * 3 + 1]), Int(s[i * 3 + 2]))
              }
              let o = (y * w + x) * 3
              for c in 0..<3 { d[o + c] = UInt16(min(65535, (sum[c] + scale / 2) / scale)) }
            }
          }
        }
      }
      return out
    }
    return LeakImage(width: w, height: h, data: pass(pass(image.data, across: true), across: false))
  }
}

// MARK: - OpenAI

/// The image model that makes the clean reference: OpenAI's image edits, called only when the
/// user confirms, with a 1536 px JPEG of the positive and no metadata. One request, never retried;
/// no SDK, credential file or other endpoint.
enum LeakOpenAI {
  static let endpoint = URL(string: "https://api.openai.com/v1/images/edits")!
  static let models = ["gpt-image-2.5-sunburst", "gpt-image-2.5-flare", "gpt-image-2"]
  static let defaultModel = models[0]
  static let promptVersion = "chromatic-only-exposure-preserving-v2"
  static let prompt = """
    TASK: This is a real color-negative film photograph, already inverted to a positive image. Produce a conservative color-restoration reference of EXACTLY this photograph. Change ONLY the broad, uneven red/magenta film light-leak color contamination. Correct its chromatic cast, not the photographic exposure.
    EXPOSURE MUST STAY: Preserve the input exposure, local luminance, white point, highlight brightness and highlight roll-off. Keep bright areas just as bright, even when their unwanted red/pink cast is removed. Do not interpret bright clouds, sunlight, sunset glow, haze, surf, reflections or lamps as overexposure to recover. Do not darken the sky or replace bright pink clouds with darker blue/gray clouds. Do not perform dehazing, HDR, highlight recovery, tone mapping, contrast enhancement, black-point crushing or cinematic color grading. If neutralizing the leak would require darkening a natural highlight, prioritize its original brightness over perfectly neutral color. A small residual cast is preferable to changed exposure. Preserve genuine warm illumination, natural atmospheric haze, shadows and vignetting; do not invent a new lighting scheme.
    COLOR MUST STAY: Preserve authentic CineStill-style red halation around bright practical lights, real red objects, signs and indicators. Do not globally desaturate red. Do not neutralize genuine sunset colors or warm lighting as if they were contamination.
    DETAILS MUST STAY: No recompose, crop, perspective change, moved edges or altered objects. Keep all structures, cloud shapes, shorelines, vegetation and objects in their exact positions and shapes. Do not invent, remove, duplicate or beautify anything. Do not denoise, blur, sharpen or replace film grain. Preserve surface variation and detail.
    OUTPUT: Return only the restored full-frame photograph, same composition and aspect ratio, without borders, labels or comparison layout. This is a broad low-frequency COLOR reference, NOT a desired exposure or illumination target; original pixels remain the final detail source.
    """
  static func buildPrompt(scene: String, note: String) -> String {
    let context: String
    switch scene {
    case "day":
      context = "DAY / NATURAL LIGHT: Preserve the original luminous clouds, sky, white surf, sunlit surfaces and atmospheric softness. Do not make a dramatic, darker or more contrasty landscape."
    case "night":
      context = "NIGHT / PRACTICAL LIGHTS: Preserve the original low-key exposure, bright lamp cores, red halation and warm illuminated surfaces. Do not dim lamps or lift the whole scene into daylight."
    default:
      context = "MIXED OR UNCERTAIN LIGHT: Do not assume a new time of day. Keep both natural highlights and practical light sources at their original brightness."
    }
    let extra = note.isEmpty ? "" : "\nAdditional user restoration preference (must not override exposure, halation or detail preservation above): " + String(note.prefix(2000))
    return prompt + "\n" + context + extra
  }
  static func outputSize(_ w: Int, _ h: Int) throws -> String {
    let r = Double(w) / Double(h)
    if r > 3 || r < 1.0 / 3 { throw DeskError.message("图像 API 要求长宽比不超过 3:1，请先裁切。") }
    let k = 1536 / Double(max(w, h))
    func side(_ v: Int) -> Int { max(16, Int((Double(v) * k / 16 + 0.5).rounded(.down)) * 16) }
    return "\(side(w))x\(side(h))"
  }
  /// `message` with the key, and anything that looks like one, taken out.
  static func redact(_ message: String, key: String) -> String {
    var text = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[REDACTED]")
    text = text.replacingOccurrences(of: "sk-[A-Za-z0-9_-]+", with: "[REDACTED]", options: .regularExpression)
    return text
  }
  struct Request {
    var apiKey: String
    var model: String
    var quality: String
    var jpeg: Data
    var width: Int
    var height: Int
    var note: String
    var scene: String
  }
  /// The request body, without the key.
  static func body(_ r: Request) throws -> [String: Any] {
    [
      "model": r.model, "prompt": buildPrompt(scene: r.scene, note: r.note),
      "images": [["image_url": "data:image/jpeg;base64," + r.jpeg.base64EncodedString()]],
      "n": 1, "quality": r.quality, "size": try outputSize(r.width, r.height), "output_format": "png", "background": "opaque",
    ]
  }
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  }
  static func session(protocols: [AnyClass]? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 900
    configuration.timeoutIntervalForResource = 900
    configuration.urlCache = nil
    if let protocols { configuration.protocolClasses = protocols }
    return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }
  /// The generated reference's PNG bytes and what to record about the request.
  static func edit(_ r: Request, session: URLSession = session()) async throws -> (bytes: Data, meta: LeakJob.Generated) {
    guard !r.apiKey.isEmpty else { throw DeskError.message("请先在“API 管理”中填写 OpenAI API Key。不要把 Key 发到聊天中。") }
    guard models.contains(r.model) else { throw DeskError.message("不支持的图像模型") }
    guard ["medium", "high"].contains(r.quality) else { throw DeskError.message("只支持 medium / high 质量") }
    let body = try body(r)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer " + r.apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let data: Data, response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .timedOut {
      throw DeskError.message("API 等待超时；请求可能已计费。工具不会自动重试，请先检查 API 使用记录。")
    } catch {
      throw DeskError.message("无法连接 OpenAI：" + redact(error.localizedDescription, key: r.apiKey) + "。未自动重试。")
    }
    guard let http = response as? HTTPURLResponse else { throw DeskError.message("API 返回内容不完整；可能已计费，未自动重试。") }
    let requestID = http.value(forHTTPHeaderField: "x-request-id")
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard (200..<300).contains(http.statusCode) else {
      let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
      let tips = [401: "API Key 无效或项目权限不足", 403: "账号 / 模型访问权限不足，可能需要组织验证", 429: "额度不足或达到速率限制", 400: "图像请求参数未被接受"]
      throw DeskError.message(
        "OpenAI \(http.statusCode)：\(tips[http.statusCode] ?? "生成失败")。\(String(redact(detail, key: r.apiKey).prefix(600)))"
          + (requestID.map { "（请求 \($0)）" } ?? "") + " 未自动重试。")
    }
    guard let json else { throw DeskError.message("API 返回内容不完整；可能已计费，未自动重试。") }
    guard let b64 = ((json["data"] as? [[String: Any]])?.first)?["b64_json"] as? String, b64.count <= 100_000_000,
      let bytes = Data(base64Encoded: b64)
    else { throw DeskError.message("API 没有返回有效的 base64 图像。未自动重试。") }
    guard bytes.count >= 24 else { throw DeskError.message("API 返回图像为空。") }
    let usage = json["usage"] as? [String: Any]
    let meta = LeakJob.Generated(
      provider: "OpenAI", model: r.model, quality: r.quality, promptVersion: promptVersion,
      promptScene: ["day", "night"].contains(r.scene) ? r.scene : "mixed", size: (json["size"] as? String) ?? (body["size"] as? String) ?? "",
      requestId: requestID, usage: usage.map { .init(total_tokens: $0["total_tokens"] as? Int, input_tokens: $0["input_tokens"] as? Int, output_tokens: $0["output_tokens"] as? Int) },
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      uploaded: .init(width: r.width, height: r.height, bytes: r.jpeg.count), endpoint: endpoint.absoluteString)
    return (bytes, meta)
  }
}

// MARK: - The API key, in the Keychain

/// One generic password of this app's own, holding the key and the chosen model. Never any other
/// item; nothing in files, logs, jobs or presets.
final class LeakKeychain {
  let service: String
  let account = "openai-api"
  let keychain: SecKeychain?
  init(service: String = "local.epscan.mac.openai", keychain: SecKeychain? = nil) {
    self.service = service
    self.keychain = keychain
  }
  struct Failure: Error { let status: OSStatus }
  private func query() -> [String: Any] {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    if let keychain { q[kSecMatchSearchList as String] = [keychain] }
    return q
  }
  func load(interactive: Bool = false) throws -> Data? {
    var q = query()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecUseAuthenticationUI as String] = interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
    return data
  }
  func save(_ data: Data) throws {
    let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "Epson Scan plus · OpenAI API"]
    var status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var q = query()
      q.removeValue(forKey: kSecMatchSearchList as String)
      if let keychain { q[kSecUseKeychain as String] = keychain }
      q.merge(attributes) { _, new in new }
      status = SecItemAdd(q as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }
  func clear() throws {
    let status = SecItemDelete(query() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
  }
}

/// The key in memory and, when the user asks, in the Keychain. It is never shown again.
final class LeakCredentials: ObservableObject {
  @Published private(set) var configured = false
  @Published private(set) var remembered = false
  @Published private(set) var storageError: String?
  @Published private(set) var model = LeakOpenAI.defaultModel
  private var key = ""
  let store: LeakKeychain
  init(store: LeakKeychain = LeakKeychain()) { self.store = store }
  var secret: String { key }
  static func valid(_ key: String) -> Bool {
    key.count <= 500 && key.trimmingCharacters(in: .whitespaces).count >= 12 && key.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\0")) == nil
  }
  private struct Record: Codable { var apiKey: String, model: String }
  /// The saved key, if any; without asking unless `interactive`.
  func restore(interactive: Bool = false) {
    do {
      if let data = try store.load(interactive: interactive) {
        guard let record = try? JSONDecoder().decode(Record.self, from: data), Self.valid(record.apiKey), LeakOpenAI.models.contains(record.model)
        else { throw LeakKeychain.Failure(status: errSecDecode) }
        key = record.apiKey.trimmingCharacters(in: .whitespaces)
        model = record.model
        remembered = true
      } else if remembered {
        remembered = false
      }
      configured = !key.isEmpty
      storageError = nil
    } catch {
      storageError = "未能读取已保存的 Key。请检查 macOS 钥匙串授权；也可取消“记住”并使用临时 Key。未删除原有凭据。"
    }
  }
  /// A new key (empty keeps the current one) and model, remembered in the Keychain or for this
  /// session only. Nothing is sent anywhere.
  func update(apiKey: String, model: String, remember: Bool) throws {
    guard LeakOpenAI.models.contains(model) else { throw DeskError.message("不支持的图像模型") }
    let typed = apiKey.trimmingCharacters(in: .whitespaces)
    guard typed.isEmpty || Self.valid(typed) else { throw DeskError.message("API Key 格式无效") }
    let next = typed.isEmpty ? key : typed
    if remember {
      guard !next.isEmpty else { throw DeskError.message("请先输入 API Key，再选择记住。") }
      do {
        try store.save(JSONEncoder().encode(Record(apiKey: next, model: model)))
      } catch {
        throw DeskError.message("macOS 钥匙串保存未完成。若出现系统授权窗口，请允许后重试；不会改存明文文件。")
      }
    } else if remembered {
      try? store.clear()
    }
    key = next
    self.model = model
    remembered = remember
    configured = !key.isEmpty
    if remember { storageError = nil }
  }
  /// Forgets the key here and in the Keychain; the key on the API platform is not revoked.
  func clear() {
    try? store.clear()
    key = ""
    remembered = false
    configured = false
    storageError = nil
  }
}
