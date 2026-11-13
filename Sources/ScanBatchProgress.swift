import Foundation

/// A batch counts completed files, not selection changes or driver progress resets. One pass of
/// the head can scan several frames of a row; they count as they arrive together.
struct ScanBatchProgress {
  enum Phase { case idle, running, cancelling, completed, cancelled, failed }
  private(set) var total = 0
  private(set) var completed = 0
  private(set) var current: Int?
  /// Frames in the pass under way.
  private(set) var currentCount = 1
  private(set) var phase = Phase.idle
  /// When the batch began, and how long its plan said it would take (`ScanPlan.seconds`): for the
  /// time left.
  var startedAt: Date?
  var plannedSeconds: Double?

  init(total: Int = 0) {
    self.total = max(0, total)
    phase = total > 0 ? .running : .idle
  }
  var isActive: Bool { phase == .running || phase == .cancelling }
  /// What the Dock icon shows while the batch runs: the frames done of all, as 「3/12」; nothing
  /// before or after.
  var badge: String? { isActive ? "\(completed)/\(total)" : nil }
  mutating func beginFrame(count: Int = 1) {
    guard phase == .running, current == nil, completed < total else { return }
    current = completed + 1
    currentCount = max(1, min(count, total - completed))
  }
  mutating func completeFrame() {
    guard isActive, current != nil else { return }
    completed += currentCount
    current = nil
    currentCount = 1
    if completed == total { phase = .completed }
  }
  mutating func requestCancellation() {
    guard isActive else { return }
    phase = .cancelling
  }
  mutating func stop(cancelled: Bool) {
    guard isActive else { return }
    current = nil
    phase = cancelled ? .cancelled : .failed
  }
  static func normalized(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0
  }
  func fraction(frameProgress: Double) -> Double {
    guard total > 0 else { return 0 }
    // Reserve the final increment for a received file plus a successful terminal callback.
    let partial = isActive && current != nil ? min(0.99, Self.normalized(frameProgress)) * Double(currentCount) : 0
    return (Double(completed) + partial) / Double(total)
  }
  /// Seconds left: the plan's at first, then more and more the pace so far, wholly once a fifth is
  /// done. Nil without a plan.
  func remaining(frameProgress: Double, now: Date = Date()) -> Double? {
    guard isActive, let startedAt, let planned = plannedSeconds, planned > 0 else { return nil }
    let done = fraction(frameProgress: frameProgress), elapsed = max(0, now.timeIntervalSince(startedAt))
    let byPlan = max(0, planned - elapsed)
    guard done > 0.02 else { return byPlan }
    let byPace = elapsed / done * (1 - done), w = min(1, done / 0.2)
    return byPlan * (1 - w) + byPace * w
  }
  static func left(_ seconds: Double) -> String {
    seconds < 60 ? "不到 1 分钟" : "约剩 \(Int((seconds / 60).rounded(.up))) 分钟"
  }
  func label(frameProgress: Double, now: Date = Date()) -> String {
    if phase == .cancelling { return "正在取消 · 已完成 \(completed) / \(total) 张" }
    let left = remaining(frameProgress: frameProgress, now: now).map { " · " + Self.left($0) } ?? ""
    if isActive, let current {
      let p = Self.normalized(frameProgress), percent = Int(p * 100)
      // Before the first data the head moves to the frame and calibrates, some 8–17 s a pass.
      let doing = p <= 0 ? "定位、校准…" : "\(percent)%"
      return currentCount > 1
        ? "第 \(current)–\(current + currentCount - 1) / \(total) 张 · 本行 \(doing)" + left
        : "第 \(current) / \(total) 张 · 本张 \(doing)" + left
    }
    if isActive { return "已完成 \(completed) / \(total) 张 · 准备下一张" + left }
    return summary
  }
  var summary: String {
    switch phase {
    case .completed: return "扫描完成 · \(completed) / \(total) 张"
    case .cancelled: return "扫描已取消 · 已完成 \(completed) / \(total) 张"
    case .failed: return "扫描中断 · 已完成 \(completed) / \(total) 张"
    default: return "已完成 \(completed) / \(total) 张"
    }
  }
}
