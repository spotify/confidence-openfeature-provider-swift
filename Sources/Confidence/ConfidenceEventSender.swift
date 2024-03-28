import Foundation

/// Sends events to Confidence. Contextual data is appended to each event
// TODO: Add functions for sending events with payload
public protocol ConfidenceEventSender: Contextual {
    func send(eventName: String)
}
