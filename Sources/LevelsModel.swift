import Foundation

/// 色阶's edits, as Photoshop's Levels makes them: its points dragged or typed, its eyedroppers and
/// its 自动. Each a step of the undo history, a drag one step (`change`).
extension AppModel {
  /// The frame's levels changed as `mutate` changes them; no change left is none (`Levels.normalized`).
  func changeLevels(_ name: String, separate: Bool = false, _ mutate: (inout Levels) -> Void) {
    change(name, separate: separate) { s in
      var l = s.levels ?? Levels()
      mutate(&l)
      s.levels = l.normalized
    }
  }
  /// An eyedropper's press: `v`, the colour under it as it came out of the levels (the picture
  /// before the curves). Black and white set each channel's input end at what it read before
  /// them, so that colour prints black or white; grey sets each channel's midtone so it prints a
  /// grey of its own lightness. The eyedropper stays picked up, as Photoshop's does.
  func pickLevelsPoint(_ picker: LevelsPicker, afterLevels v: RGB) {
    guard selected != nil else { return }
    let l = settings.levels ?? Levels()
    // Before the channel's own levels: what the channel reads there.
    let before = RGB(r: l.input(v.r, 0), g: l.input(v.g, 1), b: l.input(v.b, 2))
    switch picker {
    case .black:
      changeLevels("色阶黑场", separate: true) { lv in
        for c in 0..<3 { lv[c + 1].black = min(max(0, before.values[c]), lv[c + 1].white - 2 / 255) }
      }
      status = String(format: "黑场：这里的红 %.0f、绿 %.0f、蓝 %.0f 定为黑", before.r * 255, before.g * 255, before.b * 255)
    case .white:
      changeLevels("色阶白场", separate: true) { lv in
        for c in 0..<3 { lv[c + 1].white = max(min(1, before.values[c]), lv[c + 1].black + 2 / 255) }
      }
      status = String(format: "白场：这里的红 %.0f、绿 %.0f、蓝 %.0f 定为白", before.r * 255, before.g * 255, before.b * 255)
    case .grey:
      changeLevels("色阶灰场", separate: true) { $0.setNeutral(v) }
      status = "灰场：这里定为中性灰，亮度不变（改的是红、绿、蓝各自的中间调）"
    }
  }
  /// Photoshop's 自动 with `options`, on the picture before the levels; the output ends kept.
  func autoLevelsLikePhotoshop(_ options: LevelsAutoOptions) {
    guard let h = levelsHistogram, selected != nil else {
      status = "在单张视图里打开这张，再点色阶的「自动」"
      return
    }
    let next = Levels.auto(h, options: options, keepingOutput: settings.levels)
    changeLevels("自动色阶", separate: true) { $0 = next }
    status = "自动色阶：" + options.algorithm.name + String(format: "，暗部、高光各剪切 %.2f%%", options.shadowClip)
      + (options.snapNeutralMidtones ? "，对齐中性中间调" : "")
  }
}
