import Foundation

/// 快照, as Lightroom's: a frame's ③ grading as it was, kept with the roll under a name, so the
/// grade can be tried another way and taken back with one click.
struct GradeSnapshot: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var made: Date
  /// The frame's settings with its grading as it was; only the grading is read back.
  var adjustments: Adjustments
}

extension AppModel {
  /// The frame shown's snapshots, the oldest first.
  var shownSnapshots: [GradeSnapshot] { selectedID.flatMap { gradeSnapshots[$0] } ?? [] }
  /// What the next snapshot is called unless named: 快照 and the time, numbered when the frame
  /// already has one of that name (two in a minute), so a default name never replaces one.
  var nextSnapshotName: String {
    let plain = "快照 " + Date().formatted(date: .omitted, time: .shortened)
    let taken = Set(shownSnapshots.map(\.name))
    guard taken.contains(plain) else { return plain }
    return (2...).lazy.map { "\(plain) (\($0))" }.first { !taken.contains($0) } ?? plain
  }
  /// The frame shown's grading kept as a snapshot named `name`; one of that name on it replaced.
  func takeSnapshot(named name: String) {
    guard let f = selected else { return }
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = typed.isEmpty ? nextSnapshotName : typed
    var grading = Adjustments()
    grading.takeGrading(from: f.adjustments)
    var list = (gradeSnapshots[f.id] ?? []).filter { $0.name != name }
    list.append(GradeSnapshot(name: name, made: Date(), adjustments: grading))
    gradeSnapshots[f.id] = list
    saveProject()
    status = "已存快照「\(name)」：第 \(f.name) 张现在的调色"
  }
  /// The frame shown's grading as `s` kept it, as one edit; ② 去色罩's settings as they are.
  func restoreSnapshot(_ s: GradeSnapshot) {
    guard selected != nil, !isWorking else { return }
    change("回到快照「\(s.name)」", separate: true, syncing: false) { $0.takeGrading(from: s.adjustments) }
    status = "已回到快照「\(s.name)」 · ⌘Z 撤销"
  }
  func deleteSnapshot(_ s: GradeSnapshot) {
    guard let id = selectedID else { return }
    gradeSnapshots[id]?.removeAll { $0.id == s.id }
    if gradeSnapshots[id]?.isEmpty == true { gradeSnapshots[id] = nil }
    saveProject()
    status = "已删除快照「\(s.name)」"
  }
}
