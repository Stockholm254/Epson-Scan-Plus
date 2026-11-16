import Foundation

/// 色阶's edits, as Photoshop's Levels makes them: its points dragged or typed, its eyedroppers and
/// its 自动. Each a step of the undo history, a drag one step (`change`). From 0.24 they are 色阶 in
/// the conversion (`Adjustments.printLevels`); the levels a frame was set with on the picture as
/// shown before then (`Adjustments.levels`) and 影调's old 白色 and 黑色 stay as they were until
/// cleared.
extension AppModel {
  /// The frame's levels changed as `mutate` changes them; no change left is none (`Levels.normalized`).
  func changeLevels(_ name: String, separate: Bool = false, _ mutate: (inout Levels) -> Void) {
    change(name, separate: separate) { s in
      var l = s.printLevels ?? Levels()
      mutate(&l)
      s.printLevels = l.normalized
    }
  }
  /// An eyedropper's press: `reading`, what lies under it as the levels take it in (on the
  /// print's scale, `PrintLevelsInput`). Black and white set each channel's input end there, so
  /// that colour prints black or white; grey sets each channel's midtone so it prints a grey of its
  /// own lightness. The eyedropper stays picked up, as Photoshop's does.
  func pickLevelsPoint(_ picker: LevelsPicker, reading v: RGB) {
    guard selected != nil else { return }
    let l = settings.printLevels ?? Levels(), domain = Levels.printDomain
    switch picker {
    case .black:
      changeLevels("色阶黑场", separate: true) { lv in
        for c in 0..<3 { lv[c + 1].black = min(max(domain.lowerBound, v.values[c]), lv[c + 1].white - 2 / 255) }
      }
      status = String(format: "黑场：这里的红 %.0f、绿 %.0f、蓝 %.0f 定为黑", v.r * 255, v.g * 255, v.b * 255)
    case .white:
      changeLevels("色阶白场", separate: true) { lv in
        for c in 0..<3 { lv[c + 1].white = max(min(domain.upperBound, v.values[c]), lv[c + 1].black + 2 / 255) }
      }
      status = String(format: "白场：这里的红 %.0f、绿 %.0f、蓝 %.0f 定为白", v.r * 255, v.g * 255, v.b * 255)
    case .grey:
      let after = RGB(r: l.printValue(v.r, 0), g: l.printValue(v.g, 1), b: l.printValue(v.b, 2))
      changeLevels("色阶灰场", separate: true) { $0.setNeutral(after) }
      status = "灰场：这里定为中性灰，亮度不变（改的是红、绿、蓝各自的中间调）"
    }
  }
  /// Photoshop's 自动 with `options`, on the picture as the levels take it in; the output ends kept.
  func autoLevelsLikePhotoshop(_ options: LevelsAutoOptions) {
    guard let h = levelsHistogram, selected != nil else {
      status = "在单张视图里打开这张，再点色阶的「自动」"
      return
    }
    let next = Levels.autoPrint(h, options: options, keepingOutput: settings.printLevels)
    changeLevels("自动色阶", separate: true) { $0 = next }
    status = "自动色阶：" + options.algorithm.name + String(format: "，暗部、高光各剪切 %.2f%%", options.shadowClip)
      + (options.snapNeutralMidtones ? "，对齐中性中间调" : "")
  }
  /// The levels set on the picture as shown before 0.24 (`Adjustments.levels`) taken off; ⌘Z brings them back.
  func clearOldLevels() {
    guard settings.levels != nil else { return }
    change("清掉旧的色阶", separate: true) { $0.levels = nil }
    status = "旧的色阶已清掉 · ⌘Z 撤销"
  }
  /// 影调's old 白色 and 黑色 (and 压高光) taken off; ⌘Z brings them back.
  func clearOldWhitesBlacks() {
    guard settings.whites != nil || settings.blacks != nil || settings.pressHighlights != nil else { return }
    change("清掉旧的白色、黑色", separate: true) { (a: inout Adjustments) in (a.whites, a.blacks, a.pressHighlights) = (nil, nil, nil) }
    status = "旧的白色、黑色已清掉 · ⌘Z 撤销"
  }
}
