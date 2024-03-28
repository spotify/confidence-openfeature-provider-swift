import Foundation

/// A Contextual implementer maintains context data and can create child instances
/// that can still access their parent's data
public protocol Contextual {
    // TODO: Add complex type to the context Dictionary
    var context: [String: String] { get set }

    func updateContextEntry(key: String, value: String)
    func removeContextEntry(key: String)
    func clearContext()
    /// Creates a child Contextual instance that still has access
    /// to its parent context
    func withContext(_ context: [String: String]) -> Self
}
