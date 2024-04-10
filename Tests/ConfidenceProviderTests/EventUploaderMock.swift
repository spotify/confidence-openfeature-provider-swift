import Foundation
import Combine
@testable import Confidence

final class EventUploaderMock: EventsUploader {
    var calledRequest: [Event]? = nil
    let subject: PassthroughSubject<Int, Never> = PassthroughSubject()
    func upload(request: [Event]) async -> Bool {
        calledRequest = request
        subject.send(1)
        return true
    }

    func reset() {
        calledRequest = nil
    }
}

final class ClockMock: Clock {
    func now() -> Date {
        return Date()
    }
}

final class EventStorageMock: EventStorage {
    private var events: [Event] = []
    private var batches: [String: [Event]] = [:]
    func startNewBatch() throws {
        batches[("\(batches.count)")] = events
        events.removeAll()
    }
    
    func writeEvent(event: Event) throws {
        events.append(event)
    }
    
    func batchReadyIds() -> [String] {
        return batches.map({ batch in batch.0})
    }
    
    func eventsFrom(id: String) throws -> [Event] {
        return batches[id]!
    }
    
    func remove(id: String) throws {
        batches.removeValue(forKey: id)
    }

}