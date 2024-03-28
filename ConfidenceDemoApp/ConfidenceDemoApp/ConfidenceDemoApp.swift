import ConfidenceProvider
import Confidence
import OpenFeature
import SwiftUI

@main
struct ConfidenceDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    self.setup()
                }
        }
    }
}

extension ConfidenceDemoApp {
    func setup() {
        guard let secret = ProcessInfo.processInfo.environment["CLIENT_SECRET"] else {
            return
        }

        // If we have no cache, then do a fetch first.
        var initializationStrategy: InitializationStrategy = .activateAndFetchAsync
        if ConfidenceFeatureProvider.isStorageEmpty() {
            initializationStrategy = .fetchAndActivate
        }

        let confidence = Confidence.Builder(clientSecret: secret)
            .withInitializationstrategy(initializationStrategy: initializationStrategy)
            .build()
        let provider = ConfidenceFeatureProvider(confidence: confidence)

        // NOTE: Using a random UUID for each app start is not advised and can result in getting stale values.
        let ctx = MutableContext(targetingKey: UUID.init().uuidString, structure: MutableStructure())
        Task {
            await OpenFeatureAPI.shared.setProviderAndWait(provider: provider, initialContext: ctx)
            confidence.send(eventName: "my_event")
        }
    }
}
