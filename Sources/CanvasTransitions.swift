import AppKit

/// A change of view the canvas plays once the new picture is drawn: what covers the canvas until
/// then, and how it goes on.
struct ViewChangeInFlight {
  enum Kind {
    /// Back from the single frame to the light table: the frame shown, and where.
    case close(id: UUID, face: CGImage?, faceRect: CGRect)
    /// Into a frame's crop or out of it, from where the frame lay.
    case edit(entering: Bool, from: CGRect)
    /// The picture turned or mirrored, from where it lay.
    case orient(turns: Int, mirror: Bool, from: CGRect)
  }
  var kind: Kind
  /// The canvas as it was, over the canvas until the change plays.
  var cover: CALayer
  /// Layers the change plays on, over or in place of the cover.
  var layers: [CALayer] = []
  /// The picture the model showed before the change.
  var over: CGImage?
  /// How the table lay before the change.
  var turnBefore: QuarterTurn
  var started = false
  /// Played at once, ahead of the new picture: until when, and it gives way to the new picture
  /// only once that is here and drawn.
  var playsUntil: Date?
  /// The canvas draws no picture under it meanwhile: the turned picture plays in its place.
  var hold: Bool
}

/// How the canvas animates the model's changes of view. Each one takes the canvas's picture
/// before the change and plays once the new picture is drawn, on the system's spring:
/// - back from a frame to the light table, the view drawing back as it closed in;
/// - into a frame's crop, the frame settling among its surroundings, and out of it, the crop
///   growing to fill the view;
/// - a frame, or the table, turned a quarter or mirrored, the picture turning over;
/// - one frame for the next, sliding in from the side it lies on;
/// - a new look (负片 / 原片 / 反相) or a sharper picture of the same frame, cross-faded;
/// - a new roll's frames coming in on the table one after another.
/// With Reduce Motion, short fades instead.
extension FilmCanvasView {
  static var stillMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  // MARK: Changes played once the new picture is here

  /// The model is about to change what the canvas shows.
  func viewWillChange(_ change: AppModel.ViewChange) {
    guard let model, let layer, bounds.width > 0, shown != nil else { return }
    finishChange()
    guard let shot = tableSnapshot() else { return }
    let kind: ViewChangeInFlight.Kind
    switch change {
    case .close:
      guard model.singleView, let id = model.selectedID else { return }
      kind = .close(id: id, face: model.displayed, faceRect: imageRect)
    case .edit(let entering):
      // Zoomed in past the canvas, the frame settles from no place of its own.
      guard model.singleView, !entering || bounds.contains(imageRect.insetBy(dx: 1, dy: 1)) else { return }
      kind = .edit(entering: entering, from: entering ? imageRect : model.canvasCrop.map { screen($0.cg) } ?? imageRect)
    case .orient(let turns, let mirror):
      // Zoomed in, the part shown turned is not the part then shown.
      guard bounds.contains(imageRect.insetBy(dx: 1, dy: 1)) else { return }
      kind = .orient(turns: turns, mirror: mirror, from: imageRect)
    }
    // Growing, the whole canvas; settling or turning, only its picture.
    let whole: Bool
    switch kind {
    case .close: whole = true
    case .edit(let entering, _): whole = !entering
    case .orient: whole = false
    }
    let cover = CALayer()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if whole {
      cover.frame = bounds
      cover.contents = shot
    } else {
      let r = imageRect.intersection(bounds), k = CGFloat(shot.width) / bounds.width
      cover.frame = r
      cover.contents = shot.cropping(to: CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k).integral)
    }
    layer.addSublayer(cover)
    CATransaction.commit()
    var hold = false
    if case .orient = kind { hold = true }
    let flight = ViewChangeInFlight(kind: kind, cover: cover, over: model.displayed, turnBefore: turn, hold: hold)
    self.change = flight
    // Where the frame goes is known now in single view, so the change plays at once, ahead of
    // the new picture, as the system turns a photo the moment it is asked.
    switch kind {
    case .orient(let turns, let mirror, let from) where model.singleView:
      let to = Self.fitted(turns % 2 != 0 ? CGSize(width: from.height, height: from.width) : from.size, in: fitArea)
      self.change?.started = true
      playOrient(turns: turns, mirror: mirror, from: from, to: to)
    case .edit(false, let from):
      self.change?.started = true
      playEdit(entering: false, from: from, to: Self.fitted(from.size, in: fitArea))
    default: break
    }
    // Should the new picture never come, the canvas shows what it has.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      if self?.change?.cover === cover, self?.change?.started == false { self?.finishChange() }
    }
  }

  /// Plays a change once the model's new picture is here; a change played ahead gives way to it.
  func settleChange() {
    guard let model, let flight = change else { return }
    if case .close = flight.kind, model.singleView { return }
    var arrived = model.displayed !== flight.over
    // The table turns with its frames: its picture, the overview, may stay the same.
    if case .orient = flight.kind, !model.singleView { arrived = true }
    if flight.started {
      if let until = flight.playsUntil, Date() >= until, arrived, !model.rendering { finishChange() }
      return
    }
    // Back on the table its last print shows at once, while a new one is made.
    if case .close = flight.kind {} else if model.rendering { return }
    guard arrived, shown != nil else { return }
    change?.started = true
    switch flight.kind {
    case .close(let id, let face, let faceRect): playClose(id: id, face: face, faceRect: faceRect)
    case .edit(let entering, let from):
      playEdit(entering: entering, from: from, to: entering ? model.canvasCrop.map { screen($0.cg) } ?? imageRect : imageRect)
    case .orient(_, let mirror, let from):
      // The table turns as far as it now lies turned from before, which its frames decide.
      let quarters = ((turn.turns - flight.turnBefore.turns) % 4 + 4) % 4
      let flipped = mirror && turn.mirrored != flight.turnBefore.mirrored
      playOrient(turns: quarters == 3 ? -1 : quarters, mirror: flipped, from: from, to: imageRect)
    }
  }

  /// The view draws back from the frame to the light table: the table, as large as the frame was
  /// shown, shrinks back about it to the whole roll, and the frame into its place on it.
  private func playClose(id: UUID, face: CGImage?, faceRect: CGRect) {
    guard let model, let layer, let flight = change, let f = model.contactFrames.first(where: { $0.id == id }),
      let table = tableSnapshot()
    else { return finishChange() }
    var cell = screen(model.contactRect(f).cg)
    if model.onSheetPage, let face, face.width > 0, face.height > 0 { cell = Self.fitted(CGSize(width: face.width, height: face.height), in: cell) }
    let still = Self.stillMotion
    let tableLayer = CALayer(), faceLayer = CALayer()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tableLayer.frame = bounds
    tableLayer.contents = table
    faceLayer.frame = cell
    faceLayer.contents = face
    faceLayer.contentsGravity = .resizeAspect
    layer.insertSublayer(tableLayer, below: flight.cover)
    layer.insertSublayer(faceLayer, below: flight.cover)
    flight.cover.opacity = 0
    faceLayer.opacity = 0
    CATransaction.commit()
    change?.layers = [tableLayer, faceLayer]
    CATransaction.begin()
    // The single view's surround gives way to the table round the frame.
    flight.cover.add(Self.fade(from: 1, to: 0, duration: still ? 0.2 : 0.12), forKey: "fade")
    if !still {
      Self.springZoom(tableLayer, from: zoomed(showing: cell, at: faceRect), to: (1, CGPoint(x: bounds.midX, y: bounds.midY)))
      Self.spring(faceLayer, from: faceRect)
      // The frame's own picture gives way to its place on the table as it arrives there.
      faceLayer.add(Self.fade(from: 1, to: 0, duration: 0.2, after: 0.3), forKey: "fade")
    }
    CATransaction.commit()
    DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0.25 : 0.6)) { [weak self] in
      if self?.change?.cover === flight.cover { self?.finishChange() }
    }
  }

  /// Into a frame's crop the frame settles among its surroundings, where its crop lies on them;
  /// out of it, the crop grows to fill the view, the surroundings going off the canvas.
  private func playEdit(entering: Bool, from: CGRect, to: CGRect) {
    guard let flight = change else { return finishChange() }
    let still = Self.stillMotion
    let cover = flight.cover, start = cover.frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if entering, !still { cover.frame = to }
    cover.opacity = 0
    CATransaction.commit()
    CATransaction.begin()
    if still {
      cover.add(Self.fade(from: 1, to: 0, duration: 0.2), forKey: "fade")
    } else {
      if entering {
        Self.spring(cover, from: start)
      } else {
        Self.springZoom(cover, from: (1, CGPoint(x: bounds.midX, y: bounds.midY)), to: zoomed(showing: from, at: to))
      }
      // Gone once it lies where the new view has it.
      cover.add(Self.fade(from: 1, to: 0, duration: 0.15, after: 0.4), forKey: "fade")
    }
    CATransaction.commit()
    if entering {
      DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0.25 : 0.6)) { [weak self] in
        if self?.change?.cover === cover { self?.finishChange() }
      }
    } else {
      // Ahead of the cropped picture: it stays, grown, until that is here.
      cover.removeAnimation(forKey: "fade")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      cover.opacity = 1
      CATransaction.commit()
      playAhead(cover, for: still ? 0.2 : 0.5)
    }
  }
  /// A change played ahead of the new picture gives way to it once both are done.
  private func playAhead(_ cover: CALayer, for duration: TimeInterval) {
    change?.playsUntil = Date().addingTimeInterval(duration)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { [weak self] in
      guard let self, self.change?.cover === cover else { return }
      self.settleChange()
    }
  }

  /// A quarter turn, or a mirror: the picture as it was turns, or turns over, into the picture as
  /// it is now, as large as the new one is shown.
  private func playOrient(turns: Int, mirror: Bool, from: CGRect, to: CGRect) {
    guard let flight = change else { return finishChange() }
    let still = Self.stillMotion
    let cover = flight.cover
    if still {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      change?.hold = false
      needsDisplay = true
      cover.opacity = 0
      CATransaction.commit()
      cover.add(Self.fade(from: 1, to: 0, duration: 0.2), forKey: "fade")
      playAhead(cover, for: 0.25)
      return
    }
    guard turns != 0 || mirror else {
      // Its frames turned, the table did not: the new picture fades in.
      change?.hold = false
      needsDisplay = true
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      cover.opacity = 0
      CATransaction.commit()
      cover.add(Self.fade(from: 1, to: 0, duration: 0.25), forKey: "fade")
      playAhead(cover, for: 0.3)
      return
    }
    let quarter = turns % 2 != 0
    // The old picture's sides, turned, against the new one's: as large as it is now shown.
    let scale = quarter ? to.width / max(1, from.height) : to.width / max(1, from.width)
    let angle = CGFloat(turns) * .pi / 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cover.position = CGPoint(x: to.midX, y: to.midY)
    CATransaction.commit()
    CATransaction.begin()
    let move = CASpringAnimation(perceptualDuration: 0.45, bounce: 0)
    move.keyPath = "position"
    move.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
    // Turned by its angle, not through its matrix, so it keeps its size on the way; mirrored, it
    // turns over edge-on, narrowing to a line and opening again mirrored, a little raised as it
    // does. It stays so until it gives way to the new picture.
    var animations: [CAAnimation] = [move]
    if mirror, let face = cover.contents, let mirrored = Self.mirrored(face as! CGImage), let canvasLayer = layer {
      // Narrowing edge-on, then its back opening: the same picture mirrored.
      let back = CALayer()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      back.bounds = cover.bounds
      back.position = CGPoint(x: to.midX, y: to.midY)
      back.contents = mirrored
      back.transform = CATransform3DMakeScale(scale, scale, 1)
      canvasLayer.addSublayer(back)
      CATransaction.commit()
      change?.layers.append(back)
      let half = 0.2, mid = (1 + scale) / 2 * 1.04
      let narrow = CABasicAnimation(keyPath: "transform.scale.x")
      narrow.fromValue = 1
      narrow.toValue = 0
      narrow.timingFunction = CAMediaTimingFunction(name: .easeIn)
      let rise = CABasicAnimation(keyPath: "transform.scale.y")
      rise.fromValue = 1
      rise.toValue = mid
      rise.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animations += [narrow, rise]
      let open = CABasicAnimation(keyPath: "transform.scale.x")
      open.fromValue = 0
      open.toValue = scale
      let settle = CABasicAnimation(keyPath: "transform.scale.y")
      settle.fromValue = mid
      settle.toValue = scale
      for a in [open, settle] {
        a.beginTime = CACurrentMediaTime() + half
        a.duration = half
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        back.add(a, forKey: a.keyPath)
      }
      for a in [narrow, rise] { a.duration = half }
    } else {
      let spin = CASpringAnimation(perceptualDuration: 0.45, bounce: 0)
      spin.keyPath = "transform.rotation.z"
      spin.fromValue = 0
      spin.toValue = angle
      let grow = CASpringAnimation(perceptualDuration: 0.45, bounce: 0)
      grow.keyPath = "transform.scale"
      grow.fromValue = 1
      grow.toValue = scale
      animations += [spin, grow]
    }
    for a in animations {
      if let spring = a as? CASpringAnimation { spring.duration = spring.settlingDuration }
      a.fillMode = .forwards
      a.isRemovedOnCompletion = false
      cover.add(a, forKey: (a as? CAPropertyAnimation)?.keyPath)
    }
    CATransaction.commit()
    playAhead(cover, for: 0.5)
  }

  /// Done, or given up: the canvas draws its own picture again.
  func finishChange() {
    guard let done = change else { return }
    change = nil
    needsDisplay = true
    // The canvas's own picture drawn before what covered it goes, so nothing blinks between.
    if done.hold { displayIfNeeded() }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    done.cover.removeFromSuperlayer()
    for l in done.layers { l.removeFromSuperlayer() }
    CATransaction.commit()
  }

  // MARK: Pictures that follow one another

  /// The single frame or the table's picture, as drawn: one frame for the next slides in from
  /// the side it lies on; a new look, or the same frame sharper, cross-fades; a page of the
  /// contact sheet for another pushes in.
  func transitionPicture(_ picture: CGImage, play: Bool) {
    guard let model, let layer else { return }
    let look = [model.contactPositive ? 1 : 0, model.showNegative ? 1 : 0, ChannelView.allCases.firstIndex(of: model.channelView) ?? 0]
    let now = (id: model.singleView ? model.selectedID : nil, look: look, size: CGSize(width: picture.width, height: picture.height))
    defer { drawnSingle = now }
    guard play, let last = drawnSingle, opening == nil, change == nil else { return }
    let still = Self.stillMotion
    let move = CATransition()
    move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    if model.singleView, let id = now.id, let was = last.id, id != was,
      let i = model.frames.firstIndex(where: { $0.id == id }), let j = model.frames.firstIndex(where: { $0.id == was })
    {
      move.type = still ? .fade : .push
      move.subtype = i > j ? .fromRight : .fromLeft
      move.duration = still ? 0.2 : 0.3
    } else if last.id == now.id, last.look != now.look {
      move.type = .fade
      move.duration = 0.25
    } else if model.singleView, last.id == now.id, now.size.width > last.size.width * 1.2, now.size.height > last.size.height * 1.2 {
      // A full scan in place of the preview: the detail comes up.
      move.type = .fade
      move.duration = 0.35
    } else {
      return
    }
    layer.add(move, forKey: "picture")
  }

  // MARK: A roll's frames coming in

  /// Notes the roll on the table; a new roll's frames, none of them there before, come in one
  /// after another (another page of the same roll does not). Whether they are still coming in.
  @discardableResult func noteFrames() -> Bool {
    guard let model, !model.singleView, model.scanner.previewSoFar == nil else { return rippleRunning }
    let ids = Set(model.frames.map(\.id))
    defer { drawnFrameIDs = ids }
    if !ids.isEmpty, ids != drawnFrameIDs, drawnFrameIDs.isDisjoint(with: ids), window != nil, !Self.stillMotion {
      rippleStart = Date()
      rippleCount = model.contactFrames.count
      rippleTimer?.invalidate()
      rippleTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
        guard let self else { return timer.invalidate() }
        self.needsDisplay = true
        if !self.rippleRunning {
          timer.invalidate()
          self.rippleStart = nil
        }
      }
    }
    return rippleRunning
  }
  /// How long a roll's frames take to come in, and whether they still are.
  var rippleDuration: TimeInterval { 0.3 + min(0.05, 0.5 / Double(max(1, rippleCount))) * Double(max(0, rippleCount - 1)) }
  var rippleRunning: Bool { rippleStart.map { Date().timeIntervalSince($0) < rippleDuration } ?? false }
  /// How far the frame at `index` has come in: 0 not yet, 1 there.
  func rippleShare(_ index: Int) -> CGFloat {
    guard let start = rippleStart else { return 1 }
    let step = min(0.05, 0.5 / Double(max(1, rippleCount)))
    let t = (Date().timeIntervalSince(start) - Double(index) * step) / 0.25
    let x = CGFloat(min(1, max(0, t)))
    return 1 - (1 - x) * (1 - x) * (1 - x)
  }

  // MARK: Shared

  /// Where a layer the canvas's size lies, scaled, so that `part` of it shows at `shownAt`: its
  /// scale, and its position.
  func zoomed(showing part: CGRect, at shownAt: CGRect) -> (scale: CGFloat, position: CGPoint) {
    let k = min(shownAt.width / max(1, part.width), shownAt.height / max(1, part.height))
    return (k, CGPoint(x: shownAt.midX - k * (part.midX - bounds.midX), y: shownAt.midY - k * (part.midY - bounds.midY)))
  }
  /// A layer the canvas's size zoomed from one scale and place to another on the system's spring,
  /// by its transform: its picture stays as it is, however large it is shown.
  static func springZoom(_ layer: CALayer, from: (scale: CGFloat, position: CGPoint), to: (scale: CGFloat, position: CGPoint)) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.position = to.position
    layer.transform = CATransform3DMakeScale(to.scale, to.scale, 1)
    CATransaction.commit()
    let move = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
    move.keyPath = "position"
    move.fromValue = NSValue(point: from.position)
    let grow = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
    grow.keyPath = "transform.scale"
    grow.fromValue = from.scale
    grow.toValue = to.scale
    for a in [move, grow] {
      a.duration = a.settlingDuration
      layer.add(a, forKey: a.keyPath)
    }
  }

  /// From `start` to where `layer` now lies, on the system's spring: half a second, a slight bounce.
  static func spring(_ layer: CALayer, from start: CGRect) {
    let move = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
    move.keyPath = "position"
    move.fromValue = NSValue(point: CGPoint(x: start.midX, y: start.midY))
    let grow = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
    grow.keyPath = "bounds.size"
    grow.fromValue = NSValue(size: start.size)
    for a in [move, grow] {
      a.duration = a.settlingDuration
      layer.add(a, forKey: a.keyPath)
    }
  }
  /// A picture mirrored left to right.
  static func mirrored(_ image: CGImage) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.translateBy(x: CGFloat(image.width), y: 0)
    ctx.scaleBy(x: -1, y: 1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()
  }
  static func fade(from: Float, to: Float, duration: TimeInterval, after delay: TimeInterval = 0) -> CABasicAnimation {
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = from
    fade.toValue = to
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    if delay > 0 {
      fade.beginTime = CACurrentMediaTime() + delay
      fade.fillMode = .backwards
    }
    return fade
  }
}
