/// Mutable fixture state shared by main-actor callbacks and their driving test.
/// The reference can cross a Sendable capture boundary; access remains isolated.
@MainActor
final class MainActorTestValue<Value> {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }
}
