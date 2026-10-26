import Combine
import SwiftUI

/// Keeps optional, injected services observable without inventing a replacement
/// service or changing their lifetime when a settings pane is mounted.
@propertyWrapper
struct OptionalObservedObject<Object: ObservableObject>: DynamicProperty {
    @ObservedObject private var observation: OptionalObjectObservation<Object>

    var wrappedValue: Object? { observation.object }

    init(wrappedValue: Object?) {
        observation = OptionalObjectObservation(wrappedValue)
    }
}

private final class OptionalObjectObservation<Object: ObservableObject>: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let object: Object?
    private var subscription: AnyCancellable?

    init(_ object: Object?) {
        self.object = object
        subscription = object?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
