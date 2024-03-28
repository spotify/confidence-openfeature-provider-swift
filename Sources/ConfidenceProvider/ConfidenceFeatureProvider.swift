import Foundation
import Confidence
import OpenFeature
import Combine
import os

/// The implementation of the Confidence Feature Provider. This implementation allows to pre-cache evaluations.
///
///
///
// swiftlint:disable type_body_length
// swiftlint:disable file_length
public class ConfidenceFeatureProvider: FeatureProvider {
    public var metadata: ProviderMetadata
    public var hooks: [any Hook] = []
    private let lock = UnfairLock()
    private var resolver: Resolver
    private let client: ConfidenceClient
    private var cache: ProviderCache
    private var overrides: [String: LocalOverride]
    private let flagApplier: FlagApplier
    private let initializationStrategy: InitializationStrategy
    private let storage: Storage
    private let eventHandler = EventHandler(ProviderEvent.notReady)
    private let confidence: Confidence?

    /// Should not be called externally, use `ConfidenceFeatureProvider.Builder`or init with `Confidence` instead.
    init(
        metadata: ProviderMetadata,
        client: RemoteConfidenceClient,
        cache: ProviderCache,
        storage: Storage,
        overrides: [String: LocalOverride] = [:],
        flagApplier: FlagApplier,
        initializationStrategy: InitializationStrategy,
        confidence: Confidence?
    ) {
        self.client = client
        self.metadata = metadata
        self.cache = cache
        self.overrides = overrides
        self.flagApplier = flagApplier
        self.initializationStrategy = initializationStrategy
        self.storage = storage
        self.confidence = confidence
        self.resolver = LocalStorageResolver(cache: cache)
    }

    /// Initialize the Provider via a `Confidence` object.
    public init(confidence: Confidence) {
        let metadata = ConfidenceMetadata(version: "0.1.4") // x-release-please-version
        let options = ConfidenceClientOptions(
            credentials: ConfidenceClientCredentials.clientSecret(secret: confidence.clientSecret),
            timeout: confidence.timeout,
            region: confidence.region)
        self.metadata = metadata
        self.cache = InMemoryProviderCache.from(storage: DefaultStorage.resolverFlagsCache())
        self.storage = DefaultStorage.resolverFlagsCache()
        self.resolver = LocalStorageResolver(cache: cache)
        self.flagApplier = FlagApplierWithRetries(
            httpClient: NetworkClient(region: options.region),
            storage: DefaultStorage.applierFlagsCache(),
            options: options,
            metadata: metadata)
        self.client = RemoteConfidenceClient(
            options: options,
            applyOnResolve: false,
            flagApplier: flagApplier,
            metadata: metadata)
        self.initializationStrategy = confidence.initializationStrategy
        self.overrides = [:]
        self.confidence = confidence
    }

    public func initialize(initialContext: OpenFeature.EvaluationContext?) {
        guard let initialContext = initialContext else {
            return
        }

        if self.initializationStrategy == .activateAndFetchAsync {
            // TODO: Set the entire context
            confidence?.context = ["targeting_key": "CACHED"]
            eventHandler.send(.ready)
        }

        Task {
            do {
                let resolveResult = try await resolve(context: initialContext)

                // update cache with stored values
                try await store(
                    with: initialContext,
                    resolveResult: resolveResult,
                    refreshCache: self.initializationStrategy == .fetchAndActivate
                )

                // signal the provider is ready after the network request is done
                if self.initializationStrategy == .fetchAndActivate {
                    // TODO: Set the entire context
                    confidence?.context = ["targeting_key": initialContext.getTargetingKey()]
                    eventHandler.send(.ready)
                }
            } catch {
                // We emit a ready event as the provider is ready, but is using default / cache values.
                eventHandler.send(.ready)
            }
        }
    }

    private func store(
        with context: OpenFeature.EvaluationContext,
        resolveResult result: ResolvesResult,
        refreshCache: Bool
    ) async throws {
        guard let resolveToken = result.resolveToken else {
            throw ConfidenceError.noResolveTokenFromServer
        }

        try self.storage.save(data: result.resolvedValues.toCacheData(context: context, resolveToken: resolveToken))

        if refreshCache {
            self.cache = InMemoryProviderCache.from(storage: self.storage)
            resolver = LocalStorageResolver(cache: cache)
        }
    }

    public func onContextSet(
        oldContext: OpenFeature.EvaluationContext?,
        newContext: OpenFeature.EvaluationContext
    ) {
        guard oldContext?.hash() != newContext.hash() else {
            return
        }

        Task {
            do {
                let resolveResult = try await resolve(context: newContext)

                // update the storage
                try await store(with: newContext, resolveResult: resolveResult, refreshCache: true)
                eventHandler.send(ProviderEvent.ready)
                // TODO: Set the entire context
                confidence?.context = ["targeting_key": newContext.getTargetingKey()]
            } catch {
                eventHandler.send(ProviderEvent.ready)
                // do nothing
            }
        }
    }

    public func getBooleanEvaluation(key: String, defaultValue: Bool, context: EvaluationContext?) throws
    -> OpenFeature.ProviderEvaluation<Bool>
    {
        return try errorWrappedResolveFlag(
            flag: key,
            defaultValue: defaultValue,
            ctx: context,
            errorPrefix: "Error during boolean evaluation for key \(key)")
    }

    public func getStringEvaluation(key: String, defaultValue: String, context: EvaluationContext?) throws
    -> OpenFeature.ProviderEvaluation<String>
    {
        return try errorWrappedResolveFlag(
            flag: key,
            defaultValue: defaultValue,
            ctx: context,
            errorPrefix: "Error during string evaluation for key \(key)")
    }

    public func getIntegerEvaluation(key: String, defaultValue: Int64, context: EvaluationContext?) throws
    -> OpenFeature.ProviderEvaluation<Int64>
    {
        return try errorWrappedResolveFlag(
            flag: key,
            defaultValue: defaultValue,
            ctx: context,
            errorPrefix: "Error during integer evaluation for key \(key)")
    }

    public func getDoubleEvaluation(key: String, defaultValue: Double, context: EvaluationContext?) throws
    -> OpenFeature.ProviderEvaluation<Double>
    {
        return try errorWrappedResolveFlag(
            flag: key,
            defaultValue: defaultValue,
            ctx: context,
            errorPrefix: "Error during double evaluation for key \(key)")
    }

    public func getObjectEvaluation(key: String, defaultValue: OpenFeature.Value, context: EvaluationContext?)
    throws -> OpenFeature.ProviderEvaluation<OpenFeature.Value>
    {
        return try errorWrappedResolveFlag(
            flag: key,
            defaultValue: defaultValue,
            ctx: context,
            errorPrefix: "Error during object evaluation for key \(key)")
    }

    public func observe() -> AnyPublisher<OpenFeature.ProviderEvent, Never> {
        return eventHandler.observe()
    }

    /// Allows you to override directly on the provider. See `overrides` on ``Builder`` for more information.
    ///
    /// For example
    ///
    ///     (OpenFeatureAPI.shared.provider as? ConfidenceFeatureProvider)?
    ///         .overrides(.field(path: "button.size", variant: "control", value: .integer(4)))
    public func overrides(_ overrides: LocalOverride...) {
        lock.locked {
            overrides.forEach { localOverride in
                self.overrides[localOverride.key()] = localOverride
            }
        }
    }

    private func resolve(context: OpenFeature.EvaluationContext) async throws -> ResolvesResult {
        do {
            let resolveResult = try await client.resolve(ctx: context)
            return resolveResult
        } catch {
            Logger(subsystem: "com.confidence.provider", category: "initialize").error(
                "Error while executing \"initialize\": \(error)")
            throw error
        }
    }

    public func errorWrappedResolveFlag<T>(flag: String, defaultValue: T, ctx: EvaluationContext?, errorPrefix: String)
    throws -> ProviderEvaluation<T>
    {
        do {
            let path = try FlagPath.getPath(for: flag)
            return try resolveFlag(path: path, defaultValue: defaultValue, ctx: ctx)
        } catch let error {
            if error is OpenFeatureError {
                throw error
            } else {
                throw OpenFeatureError.generalError(message: "\(errorPrefix): \(error)")
            }
        }
    }

    private func resolveFlag<T>(path: FlagPath, defaultValue: T, ctx: EvaluationContext?) throws -> ProviderEvaluation<
        T
    > {
        if let overrideValue: (value: T, variant: String?) = getOverride(path: path) {
            return ProviderEvaluation(
                value: overrideValue.value,
                variant: overrideValue.variant,
                reason: Reason.staticReason.rawValue)
        }

        guard let ctx = ctx else {
            throw OpenFeatureError.invalidContextError
        }

        do {
            let resolverResult = try resolver.resolve(flag: path.flag, ctx: ctx)

            guard let value = resolverResult.resolvedValue.value else {
                return resolveFlagNoValue(
                    defaultValue: defaultValue,
                    resolverResult: resolverResult,
                    ctx: ctx
                )
            }

            let pathValue: Value = try getValue(path: path.path, value: value)
            guard let typedValue: T = pathValue == .null ? defaultValue : pathValue.getTyped() else {
                throw OpenFeatureError.parseError(message: "Unable to parse flag value: \(pathValue)")
            }

            let evaluationResult = ProviderEvaluation(
                value: typedValue,
                variant: resolverResult.resolvedValue.variant,
                reason: Reason.targetingMatch.rawValue
            )

            processResultForApply(
                resolverResult: resolverResult,
                ctx: ctx,
                applyTime: Date.backport.now
            )
            return evaluationResult
        } catch ConfidenceError.cachedValueExpired {
            return ProviderEvaluation(
                value: defaultValue,
                variant: nil,
                reason: Reason.error.rawValue,
                errorCode: ErrorCode.providerNotReady)
        } catch {
            throw error
        }
    }

    private func resolveFlagNoValue<T>(defaultValue: T, resolverResult: ResolveResult, ctx: EvaluationContext)
    -> ProviderEvaluation<T>
    {
        switch resolverResult.resolvedValue.resolveReason {
        case .noMatch:
            processResultForApply(
                resolverResult: resolverResult,
                ctx: ctx,
                applyTime: Date.backport.now)
            return ProviderEvaluation(
                value: defaultValue,
                variant: nil,
                reason: Reason.defaultReason.rawValue)
        case .match:
            return ProviderEvaluation(
                value: defaultValue,
                variant: nil,
                reason: Reason.error.rawValue,
                errorCode: ErrorCode.general,
                errorMessage: "Rule matched but no value was returned")
        case .targetingKeyError:
            return ProviderEvaluation(
                value: defaultValue,
                variant: nil,
                reason: Reason.error.rawValue,
                errorCode: ErrorCode.invalidContext,
                errorMessage: "Invalid targeting key")
        case .disabled:
            return ProviderEvaluation(
                value: defaultValue,
                variant: nil,
                reason: Reason.disabled.rawValue)
        case .generalError:
            return ProviderEvaluation(
                value: defaultValue,
                variant: nil,
                reason: Reason.error.rawValue,
                errorCode: ErrorCode.general,
                errorMessage: "General error in the Confidence backend")
        }
    }

    private func getValue(path: [String], value: Value) throws -> Value {
        if path.isEmpty {
            guard case .structure = value else {
                throw OpenFeatureError.parseError(
                    message: "Flag path must contain path to the field for non-object values")
            }
        }

        var pathValue = value
        if !path.isEmpty {
            pathValue = try getValueForPath(path: path, value: value)
        }

        return pathValue
    }

    private func getValueForPath(path: [String], value: Value) throws -> Value {
        var curValue = value
        for field in path {
            guard case .structure(let values) = curValue, let newValue = values[field] else {
                throw OpenFeatureError.generalError(message: "Unable to find key '\(field)'")
            }

            curValue = newValue
        }

        return curValue
    }

    private func getOverride<T>(path: FlagPath) -> (value: T, variant: String?)? {
        let fieldPath = "\(path.flag).\(path.path.joined(separator: "."))"

        guard let overrideValue = self.overrides[fieldPath] ?? self.overrides[path.flag] else {
            return nil
        }

        switch overrideValue {
        case let .flag(_, variant, value):
            guard let pathValue = try? getValue(path: path.path, value: .structure(value)) else {
                return nil
            }
            guard let typedValue: T = pathValue.getTyped() else {
                return nil
            }

            return (typedValue, variant)

        case let .field(_, variant, value):
            guard let typedValue: T = value.getTyped() else {
                return nil
            }

            return (typedValue, variant)
        }
    }

    private func processResultForApply(
        resolverResult: ResolveResult?,
        ctx: OpenFeature.EvaluationContext?,
        applyTime: Date
    ) {
        guard let resolverResult = resolverResult, let resolveToken = resolverResult.resolveToken else {
            return
        }

        let flag = resolverResult.resolvedValue.flag
        Task {
            await flagApplier.apply(flagName: flag, resolveToken: resolveToken)
        }
    }

    private func logApplyError(error: Error) {
        switch error {
        case ConfidenceError.applyStatusTransitionError, ConfidenceError.cachedValueExpired,
            ConfidenceError.flagNotFoundInCache:
            Logger(subsystem: "com.confidence.provider", category: "apply").debug(
                "Cache data for flag was updated while executing \"apply\", aborting")
        default:
            Logger(subsystem: "com.confidence.provider", category: "apply").error(
                "Error while executing \"apply\": \(error)")
        }
    }
}

// MARK: Storage

extension ConfidenceFeatureProvider {
    public static func isStorageEmpty(
        storage: Storage = DefaultStorage.resolverFlagsCache()
    ) -> Bool {
        storage.isEmpty()
    }
}

// MARK: Builder

extension ConfidenceFeatureProvider {
    public struct Builder {
        var options: ConfidenceClientOptions
        let metadata = ConfidenceMetadata(version: "0.1.4") // x-release-please-version
        var session: URLSession?
        var localOverrides: [String: LocalOverride] = [:]
        var storage: Storage = DefaultStorage.resolverFlagsCache()
        var cache: ProviderCache?
        var flagApplier: (any FlagApplier)?
        var initializationStrategy: InitializationStrategy = .fetchAndActivate
        var confidence: Confidence?

        /// DEPRECATED
        /// Initializes the builder with the given credentails.
        ///
        ///     OpenFeatureAPI.shared.setProvider(provider:
        ///     ConfidenceFeatureProvider.Builder(credentials: .clientSecret(secret: "mysecret"))
        ///         .build()
        public init(credentials: ConfidenceClientCredentials) {
            self.options = ConfidenceClientOptions(credentials: credentials)
        }

        init(
            options: ConfidenceClientOptions,
            session: URLSession? = nil,
            localOverrides: [String: LocalOverride] = [:],
            flagApplier: FlagApplier?,
            storage: Storage,
            cache: ProviderCache?,
            initializationStrategy: InitializationStrategy
        ) {
            self.options = options
            self.session = session
            self.localOverrides = localOverrides
            self.flagApplier = flagApplier
            self.storage = storage
            self.cache = cache
            self.initializationStrategy = initializationStrategy
        }

        /// Allows the `ConfidenceClient` to be configured with a custom URLSession, useful for
        /// setting up unit tests.
        ///
        /// - Parameters:
        ///      - session: URLSession to use for connections.
        public func with(session: URLSession) -> Builder {
            return Builder(
                options: options,
                session: session,
                localOverrides: localOverrides,
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Inject custom queue for Apply request operations, useful for testing
        ///
        /// - Parameters:
        ///      - applyQueue: queue to use for sending Apply requests.
        public func with(flagApplier: FlagApplier) -> Builder {
            return Builder(
                options: options,
                session: session,
                localOverrides: localOverrides,
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Inject custom storage, useful for testing
        ///
        /// - Parameters:
        ///      - cache: cache for the provider to use.
        public func with(storage: Storage) -> Builder {
            return Builder(
                options: options,
                session: session,
                localOverrides: localOverrides,
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Inject custom cache, useful for testing
        ///
        /// - Parameters:
        ///      - cache: cache for the provider to use.
        public func with(cache: ProviderCache) -> Builder {
            return Builder(
                options: options,
                session: session,
                localOverrides: localOverrides,
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Inject custom storage for apply events, useful for testing
        ///
        /// - Parameters:
        ///      - storage: apply storage for the provider to use.
        public func with(applyStorage: Storage) -> Builder {
            return Builder(
                options: options,
                session: session,
                localOverrides: localOverrides,
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Inject custom initialization strategy
        ///
        /// - Parameters:
        ///      - storage: apply storage for the provider to use.
        public func with(initializationStrategy: InitializationStrategy) -> Builder {
            return Builder(
                options: options,
                session: session,
                localOverrides: localOverrides,
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Locally overrides resolves for specific flags or even fields within a flag. Field-level overrides are
        /// prioritized over flag-level overrides ones.
        ///
        /// For example, the following will override the size field of a flag called button:
        ///
        ///     OpenFeatureAPI.shared.setProvider(provider:
        ///         ConfidenceFeatureProvider.Builder(credentials: .clientSecret(secret: "mysecret"))
        ///         .overrides(.field(path: "button.size", variant: "control", value: .integer(4)))
        ///         .build()
        ///
        /// You can alsow override the complete flag by:
        ///
        ///     OpenFeatureAPI.shared.setProvider(provider:
        ///         ConfidenceFeatureProvider.Builder(credentials: .clientSecret(secret: "mysecret"))
        ///         .overrides(.flag(name: "button", variant: "control", value: ["size": .integer(4)]))
        ///         .build()
        ///
        /// - Parameters:
        ///      - overrides: the list of local overrides for the provider.
        public func overrides(_ overrides: LocalOverride...) -> Builder {
            let localOverrides = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key(), $0) })

            return Builder(
                options: options,
                session: session,
                localOverrides: self.localOverrides.merging(localOverrides) { _, new in new },
                flagApplier: flagApplier,
                storage: storage,
                cache: cache,
                initializationStrategy: initializationStrategy
            )
        }

        /// Creates the `ConfidenceFeatureProvider` according to the settings specified in the builder.
        public func build() -> ConfidenceFeatureProvider {
            let flagApplier =
            flagApplier
            ?? FlagApplierWithRetries(
                httpClient: NetworkClient(region: options.region),
                storage: DefaultStorage.applierFlagsCache(),
                options: options,
                metadata: metadata
            )

            let cache = cache ?? InMemoryProviderCache.from(storage: storage)

            let client = RemoteConfidenceClient(
                options: options,
                session: self.session,
                applyOnResolve: false,
                flagApplier: flagApplier,
                metadata: metadata
            )

            return ConfidenceFeatureProvider(
                metadata: metadata,
                client: client,
                cache: cache,
                storage: storage,
                overrides: localOverrides,
                flagApplier: flagApplier,
                initializationStrategy: initializationStrategy,
                confidence: confidence
            )
        }
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
