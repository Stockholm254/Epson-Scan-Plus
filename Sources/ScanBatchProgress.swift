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

  init(total: Int = 0) {
    self.total = max(0, total)
    phase = total > 0 ? .running : .idle
  }
  var isActive: Bool { phase == .running || phase == .cancelling }
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
  func label(frameProgress: Double) -> String {
    if phase == .cancelling { return "正在取消 · 已完成 \(completed) / \(total) 张" }
    if isActive, let current {
      let percent = Int(Self.normalized(frameProgress) * 100)
      return currentCount > 1
        ? "第 \(current)–\(current + currentCount - 1) / \(total) 张 · 本行 \(percent)%"
        : "第 \(current) / \(total) 张 · 本张 \(percent)%"
    }
    if isActive { return "已完成 \(completed) / \(total) 张 · 准备下一张" }
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
