/// Carries a value a dictionary or an app object across a thread hop. The type says "I checked this
/// crossing by hand": the payload is only touched on the thread that receives it.
public final class SendBox<T>: @unchecked Sendable {
    public var value: T
    public init(_ value: T) { self.value = value }
}
