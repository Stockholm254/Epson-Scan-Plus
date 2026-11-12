import Combine
import SwiftUI
import Foundation
import QuartzCore

/// What the window observes in place of the model: the model's changes passed on as they come,
/// except while a slider is dragged (`AppModel.adjustingContinuously`), when the window is updated
/// at most every 0.1 s, and once more after the last step.
///
/// Each update of the window works out and lays out all of it again, some 40 ms on a copy roll.
/// A slider sends 60 steps a second, so the window fell behind the hand and the knob stuck. The
/// picture follows every step all the same: it reaches the canvas without the window's update.
/// The views that observe the model themselves (the strip's marks, the camera's panel and the
/// like) still update with every change.
final class WindowGate: ObservableObject {
  let objectWillChange = ObservableObjectPublisher()
  /// Twice a second, as the histograms beside the picture are shown while it moves (`catchUp`):
  /// each update is some 45–60 ms on a copy roll, and at ten a second the main thread was busy all
  /// the while, the slider's knob catching on it (at four, a hitch a quarter of a second). The
  /// slider's figure follows every step all the same (`LiveFigure`), as the picture does.
  static let interval: CFTimeInterval = 0.5
  private var watching: AnyCancellable?
  private var sentAt: CFTimeInterval = 0
  private var waiting = false
  /// Updates passed on, and held back to go with a later one, for the tests.
  private(set) var sent = 0, held = 0

  init(_ model: AppModel) {
    watching = model.objectWillChange.sink { [weak self, weak model] _ in
      self?.changed(dragging: model?.adjustingContinuously == true)
    }
  }
  private func changed(dragging: Bool) {
    let now = CACurrentMediaTime()
    if !dragging && !waiting { return send(now) }
    if !waiting && now - sentAt >= Self.interval { return send(now) }
    held += 1
    guard !waiting else { return }
    // One update for all the steps until then, showing the model as the last of them left it.
    waiting = true
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.005, Self.interval - (now - sentAt))) { [weak self] in
      guard let self else { return }
      self.waiting = false
      self.send(CACurrentMediaTime())
    }
  }
  private func send(_ now: CFTimeInterval) {
    sentAt = now
    sent += 1
    objectWillChange.send()
  }
}

/// The model for a view that observes it through its gate, as the window does: `@Gated var m`.
/// For views on screen while a slider is dragged; a sheet or a page of its own can observe the
/// model itself.
@propertyWrapper struct Gated: DynamicProperty {
  let wrappedValue: AppModel
  @ObservedObject private var gate: WindowGate
  init(wrappedValue: AppModel) {
    self.wrappedValue = wrappedValue
    _gate = ObservedObject(wrappedValue: wrappedValue.windowGate)
  }
  /// `$m.key`, a binding to the model's `key`, as with `@ObservedObject`.
  var projectedValue: Bindings { Bindings(model: wrappedValue) }
  @dynamicMemberLookup struct Bindings {
    let model: AppModel
    subscript<T>(dynamicMember key: ReferenceWritableKeyPath<AppModel, T>) -> Binding<T> {
      Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0 })
    }
  }
}
