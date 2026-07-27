import Foundation

public struct APIUsageCollectorConfiguration: Equatable, Sendable {
    public let usageEnabled: Bool
    public let proxyReady: Bool
    public let port: Int
    public let profiles: [APIUsageProfileDescriptor]
    public let reportingTimeZoneID: String

    public var enabledProviders: Set<APIUsageProvider> {
        Set(profiles.map(\.provider))
    }

    public init(
        usageEnabled: Bool,
        proxyReady: Bool,
        port: Int,
        profiles: [APIUsageProfileDescriptor],
        reportingTimeZoneID: String
    ) {
        self.usageEnabled = usageEnabled
        self.proxyReady = proxyReady
        self.port = port
        self.profiles = profiles
        self.reportingTimeZoneID = reportingTimeZoneID
    }

    public init(
        usageEnabled: Bool,
        proxyReady: Bool,
        port: Int,
        enabledProviders: Set<APIUsageProvider>,
        reportingTimeZoneID: String
    ) {
        self.init(
            usageEnabled: usageEnabled,
            proxyReady: proxyReady,
            port: port,
            profiles: enabledProviders.map { provider in
                provider == .claude ? .legacyClaude : .legacyOpenAI
            },
            reportingTimeZoneID: reportingTimeZoneID
        )
    }
}

public struct APIUsageCollectorIdentity: Equatable, Hashable, Sendable {
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }
}

public struct APIUsageCollectionReport: Equatable, Sendable {
    public let identity: APIUsageCollectorIdentity
    public let statesByProfileID: [String: APICostUsageState]
    public let collectedAt: Date

    public init(
        identity: APIUsageCollectorIdentity = .init(generation: 0),
        statesByProfileID: [String: APICostUsageState],
        collectedAt: Date
    ) {
        self.identity = identity
        self.statesByProfileID = statesByProfileID
        self.collectedAt = collectedAt
    }
}

public enum APIUsageCollectorStopReason: Equatable, Sendable {
    case trackingDisabled(proxyCouldServeRequests: Bool)
    case applicationTermination
}

public protocol APIUsageCollecting: Sendable {
    func reports() async -> AsyncStream<APIUsageCollectionReport>
    func restore(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport
    func start(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport
    func update(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport
    func reload(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport
    func stop(reason: APIUsageCollectorStopReason, at: Date) async throws
}

public actor APIUsageCollector: APIUsageCollecting {
    private enum RetryDisposition {
        case normal
        case retryable
        case terminal
    }

    private enum DrainSource: Equatable {
        case lifecycle
        case polling
    }

    private struct DrainResult {
        let report: APIUsageCollectionReport
        let retryDisposition: RetryDisposition
    }

    private struct PreparedBaseline {
        let ledger: APIUsageLedgerReadModel
        let hadExistingTracking: Bool
    }

    private static let batchSize = 200
    private static let recordsPerPass = 2_000
    private static let retentionSeconds: TimeInterval = 3_600
    private static let normalPollNanoseconds: UInt64 = 30_000_000_000
    private static let retryNanoseconds: [UInt64] = [
        60_000_000_000,
        120_000_000_000,
        240_000_000_000,
        480_000_000_000,
        900_000_000_000
    ]

    private let queueClient: any APIUsageQueueFetching
    private let ledgerStore: any APIUsageLedgerStoring
    private let mapper: APIUsageRecordMapper
    private let catalog: APIPriceCatalog
    private let estimator: APICostEstimator
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void

    private var configuration: APIUsageCollectorConfiguration?
    private var initializationTask: Task<PreparedBaseline, Error>?
    private var initializationGeneration: UInt64 = 0
    private var initializationRequiresFlush = false
    private var activeInitializationGeneration: UInt64?
    private var reloadTask: Task<DrainResult, Never>?
    private var reloadGeneration: UInt64 = 0
    private var activeReloadGeneration: UInt64?
    private var activeDrainConfiguration: APIUsageCollectorConfiguration?
    private var activeDrainSource: DrainSource?
    private var flushRequestedForActiveDrain = false
    private var activeDrainDidFlush = false
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration: UInt64 = 0
    private var lifecycleStopGeneration: UInt64 = 0
    private var reportContinuation: AsyncStream<APIUsageCollectionReport>.Continuation?
    private var reportContinuationID: UUID?
    private var latestReport: APIUsageCollectionReport?
    private var reportGeneration: UInt64 = 0
    private var currentIdentity: APIUsageCollectorIdentity?

    public init(
        queueClient: any APIUsageQueueFetching = CLIProxyAPIUsageQueueClient(),
        ledgerStore: any APIUsageLedgerStoring = APIUsageLedgerStore(),
        mapper: APIUsageRecordMapper = APIUsageRecordMapper(),
        catalog: APIPriceCatalog = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.queueClient = queueClient
        self.ledgerStore = ledgerStore
        self.mapper = mapper
        self.catalog = catalog
        self.estimator = APICostEstimator(catalog: catalog)
        self.now = now
        self.sleep = sleep
    }

    deinit {
        pollingTask?.cancel()
        reloadTask?.cancel()
        initializationTask?.cancel()
        reportContinuation?.finish()
        let ledgerStore = ledgerStore
        Task {
            await ledgerStore.releaseCollectorWriterLease()
        }
    }

    public func reports() async -> AsyncStream<APIUsageCollectionReport> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            reportContinuation?.finish()
            reportContinuation = continuation
            reportContinuationID = id
            if let latestReport {
                continuation.yield(latestReport)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeReportContinuation(id: id)
                }
            }
        }
    }

    public func restore(
        configuration: APIUsageCollectorConfiguration
    ) async -> APIUsageCollectionReport {
        let identity = nextIdentity()
        self.configuration = configuration
        let report = await restoredReport(
            configuration: configuration,
            identity: identity,
            at: now()
        )
        publish(report, for: configuration)
        return report
    }

    public func start(
        configuration: APIUsageCollectorConfiguration
    ) async -> APIUsageCollectionReport {
        let identity = nextIdentity()
        let stopGeneration = lifecycleStopGeneration
        self.configuration = configuration
        await cancelPolling()
        guard lifecycleStopGeneration == stopGeneration else {
            return await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
        }

        guard configuration.usageEnabled else {
            try? await stop(
                reason: .trackingDisabled(proxyCouldServeRequests: configuration.proxyReady),
                at: now()
            )
            let report = disabledReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }

        let startedAt = now()
        do {
            _ = try await sharedInitialization(
                configuration: configuration,
                at: startedAt,
                forcePreparation: true
            )
            guard lifecycleStopGeneration == stopGeneration,
                  self.configuration?.usageEnabled == true else {
                return await restoredReport(
                    configuration: configuration,
                    identity: identity,
                    at: now()
                )
            }
            try await ledgerStore.markResumed(at: startedAt)
            guard lifecycleStopGeneration == stopGeneration,
                  self.configuration == configuration else {
                return await restoredReport(
                    configuration: configuration,
                    identity: identity,
                    at: now()
                )
            }
        } catch {
            let failedAt = now()
            let ledger = try? await ledgerStore.readCurrentPeriods(at: failedAt)
            let report = report(
                configuration: configuration,
                identity: identity,
                ledger: ledger,
                ledgerError: error,
                at: failedAt
            )
            publish(report, for: configuration)
            return report
        }

        guard !configuration.enabledProviders.isEmpty else {
            let report = await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }
        guard configuration.proxyReady else {
            let report = await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }

        let result = await sharedDrain(
            configuration: configuration,
            identity: identity,
            flushAfterDrain: false,
            source: .lifecycle,
            stopGeneration: stopGeneration
        )
        startPolling(
            after: result,
            configuration: configuration,
            identity: identity,
            stopGeneration: stopGeneration
        )
        return result.report
    }

    public func update(
        configuration: APIUsageCollectorConfiguration
    ) async -> APIUsageCollectionReport {
        let stopGeneration = lifecycleStopGeneration
        let previous = self.configuration
        self.configuration = configuration
        await cancelPolling()
        guard lifecycleStopGeneration == stopGeneration else {
            let identity = nextIdentity()
            return await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
        }

        if previous == nil || previous?.usageEnabled == false {
            return await start(configuration: configuration)
        }
        let identity = nextIdentity()

        guard configuration.usageEnabled else {
            try? await stop(
                reason: .trackingDisabled(proxyCouldServeRequests: configuration.proxyReady),
                at: now()
            )
            let report = disabledReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }

        guard !configuration.enabledProviders.isEmpty else {
            let report = await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }
        guard configuration.proxyReady else {
            let report = await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }

        let result = await sharedDrain(
            configuration: configuration,
            identity: identity,
            flushAfterDrain: false,
            source: .lifecycle,
            stopGeneration: stopGeneration
        )
        startPolling(
            after: result,
            configuration: configuration,
            identity: identity,
            stopGeneration: stopGeneration
        )
        return result.report
    }

    public func reload(
        configuration: APIUsageCollectorConfiguration
    ) async -> APIUsageCollectionReport {
        let identity = nextIdentity()
        let stopGeneration = lifecycleStopGeneration
        self.configuration = configuration
        let shouldRestartPolling = pollingTask != nil
        await cancelPolling()
        guard lifecycleStopGeneration == stopGeneration else {
            return await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
        }

        guard configuration.usageEnabled else {
            let report = disabledReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }
        guard !configuration.enabledProviders.isEmpty else {
            let report = await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }
        guard configuration.proxyReady else {
            let report = await restoredReport(
                configuration: configuration,
                identity: identity,
                at: now()
            )
            publish(report, for: configuration)
            return report
        }

        let result = await sharedDrain(
            configuration: configuration,
            identity: identity,
            flushAfterDrain: true,
            source: .lifecycle,
            stopGeneration: stopGeneration
        )
        if shouldRestartPolling,
           self.configuration == configuration,
           lifecycleStopGeneration == stopGeneration {
            startPolling(
                after: result,
                configuration: configuration,
                identity: identity,
                stopGeneration: stopGeneration
            )
        }
        return result.report
    }

    public func stop(reason: APIUsageCollectorStopReason, at: Date) async throws {
        lifecycleStopGeneration &+= 1
        initializationTask?.cancel()
        if activeDrainSource == .lifecycle {
            reloadTask?.cancel()
        }
        await cancelPolling()
        await waitForActiveInitialization()
        await waitForActiveLifecycleDrain()
        await cancelPolling()

        do {
            switch reason {
            case let .trackingDisabled(proxyCouldServeRequests):
                try await ledgerStore.markPaused(
                    at: at,
                    proxyCouldServeRequests: proxyCouldServeRequests
                )
                try await ledgerStore.flush()
            case .applicationTermination:
                try await ledgerStore.flush()
            }
            await ledgerStore.releaseCollectorWriterLease()
        } catch {
            if let configuration {
                let ledger = try? await ledgerStore.readCurrentPeriods(at: at)
                let report = report(
                    configuration: configuration,
                    identity: currentIdentity ?? .init(generation: 0),
                    ledger: ledger,
                    ledgerError: error,
                    at: at
                )
                publish(report, for: configuration)
            }
            throw error
        }
    }

    private func sharedDrain(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        flushAfterDrain: Bool,
        source: DrainSource,
        stopGeneration: UInt64
    ) async -> DrainResult {
        if let reloadTask, let generation = activeReloadGeneration {
            if activeDrainConfiguration == configuration {
                if flushAfterDrain {
                    flushRequestedForActiveDrain = true
                }
                let result = await reloadTask.value
                finishReload(generation: generation)
                return result
            }

            let result = await reloadTask.value
            finishReload(generation: generation)
            guard lifecycleStopGeneration == stopGeneration else {
                return result
            }
            return await sharedDrain(
                configuration: configuration,
                identity: identity,
                flushAfterDrain: flushAfterDrain,
                source: source,
                stopGeneration: stopGeneration
            )
        }

        reloadGeneration &+= 1
        let generation = reloadGeneration
        activeReloadGeneration = generation
        activeDrainConfiguration = configuration
        activeDrainSource = source
        flushRequestedForActiveDrain = flushAfterDrain
        activeDrainDidFlush = false
        let task = Task {
            await self.performDrain(
                configuration: configuration,
                identity: identity,
                stopGeneration: stopGeneration
            )
        }
        reloadTask = task

        let result = await task.value
        finishReload(generation: generation)
        return result
    }

    private func finishReload(generation: UInt64) {
        guard activeReloadGeneration == generation else { return }
        reloadTask = nil
        activeReloadGeneration = nil
        activeDrainConfiguration = nil
        activeDrainSource = nil
        flushRequestedForActiveDrain = false
        activeDrainDidFlush = false
    }

    private func sharedInitialization(
        configuration: APIUsageCollectorConfiguration,
        at: Date,
        forcePreparation: Bool
    ) async throws -> PreparedBaseline {
        if let initializationTask,
           let generation = activeInitializationGeneration {
            do {
                let result = try await initializationTask.value
                finishInitialization(generation: generation)
                return result
            } catch {
                finishInitialization(generation: generation)
                throw error
            }
        }

        initializationGeneration &+= 1
        let generation = initializationGeneration
        activeInitializationGeneration = generation
        let task = Task {
            try await self.performInitialization(
                configuration: configuration,
                at: at,
                forcePreparation: forcePreparation
            )
        }
        initializationTask = task

        do {
            let result = try await task.value
            finishInitialization(generation: generation)
            return result
        } catch {
            finishInitialization(generation: generation)
            throw error
        }
    }

    private func performInitialization(
        configuration: APIUsageCollectorConfiguration,
        at: Date,
        forcePreparation: Bool
    ) async throws -> PreparedBaseline {
        try await ledgerStore.acquireCollectorWriterLease()
        if forcePreparation {
            initializationRequiresFlush = true
            try await ledgerStore.prepareTracking(
                at: at,
                reportingTimeZoneID: configuration.reportingTimeZoneID
            )
            try await ledgerStore.flush()
            let ledger = try await ledgerStore.readCurrentPeriods(at: at)
            initializationRequiresFlush = false
            return PreparedBaseline(ledger: ledger, hadExistingTracking: true)
        }

        if initializationRequiresFlush {
            try await ledgerStore.prepareTracking(
                at: at,
                reportingTimeZoneID: configuration.reportingTimeZoneID
            )
            try await ledgerStore.flush()
            let ledger = try await ledgerStore.readCurrentPeriods(at: at)
            initializationRequiresFlush = false
            return PreparedBaseline(ledger: ledger, hadExistingTracking: false)
        }

        do {
            return PreparedBaseline(
                ledger: try await ledgerStore.readCurrentPeriods(at: at),
                hadExistingTracking: true
            )
        } catch APIUsageLedgerStoreError.notInitialized {
            initializationRequiresFlush = true
            try await ledgerStore.prepareTracking(
                at: at,
                reportingTimeZoneID: configuration.reportingTimeZoneID
            )
            try await ledgerStore.flush()
            let ledger = try await ledgerStore.readCurrentPeriods(at: at)
            initializationRequiresFlush = false
            return PreparedBaseline(ledger: ledger, hadExistingTracking: false)
        }
    }

    private func finishInitialization(generation: UInt64) {
        guard activeInitializationGeneration == generation else { return }
        initializationTask = nil
        activeInitializationGeneration = nil
    }

    private func performDrain(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        stopGeneration: UInt64
    ) async -> DrainResult {
        let drainStartedAt = now()
        let prepared: PreparedBaseline
        do {
            prepared = try await sharedInitialization(
                configuration: configuration,
                at: drainStartedAt,
                forcePreparation: false
            )
        } catch let error as APIUsageLedgerStoreError {
            let report = report(
                configuration: configuration,
                identity: identity,
                ledger: nil,
                ledgerError: error,
                at: drainStartedAt
            )
            publish(report, for: configuration)
            return .init(report: report, retryDisposition: .terminal)
        } catch {
            let report = report(
                configuration: configuration,
                identity: identity,
                ledger: nil,
                ledgerError: error,
                at: drainStartedAt
            )
            publish(report, for: configuration)
            return .init(report: report, retryDisposition: .terminal)
        }

        let initializedBaseline = prepared.ledger
        let baseline = prepared.hadExistingTracking ? initializedBaseline : nil
        guard lifecycleStopGeneration == stopGeneration,
              self.configuration == configuration,
              !Task.isCancelled else {
            let report = reportFromBaseline(
                configuration: configuration,
                identity: identity,
                ledger: initializedBaseline,
                at: now()
            )
            publish(report, for: configuration)
            return .init(report: report, retryDisposition: .terminal)
        }

        if let lastSuccessfulDrainAt = initializedBaseline.metadata.lastSuccessfulDrainAt,
           drainStartedAt.timeIntervalSince(lastSuccessfulDrainAt) > Self.retentionSeconds {
            do {
                try await ledgerStore.markCollectionGap(
                    from: lastSuccessfulDrainAt,
                    to: drainStartedAt
                )
            } catch {
                let report = report(
                    configuration: configuration,
                    identity: identity,
                    ledger: baseline,
                    ledgerError: error,
                    at: drainStartedAt
                )
                publish(report, for: configuration)
                return .init(report: report, retryDisposition: .terminal)
            }
        }

        var latestTimestamp: Date?
        let destructiveGapStart = initializedBaseline.metadata.lastSuccessfulDrainAt
            ?? initializedBaseline.metadata.trackingStartedAt
        var hasMalformedRecordGap = false
        while true {
            var processed = 0
            var shortBatchReceived = false

            while processed < Self.recordsPerPass {
                let batch: APIUsageQueueBatch
                do {
                    batch = try await queueClient.popUsage(
                        port: configuration.port,
                        count: Self.batchSize
                    )
                } catch is CancellationError {
                    let report = reportFromBaseline(
                        configuration: configuration,
                        identity: identity,
                        ledger: baseline,
                        at: now()
                    )
                    publish(report, for: configuration)
                    return .init(report: report, retryDisposition: .terminal)
                } catch let error as APIUsageQueueClientError {
                    let failedAt = now()
                    if error == .schemaMismatch {
                        do {
                            try await ledgerStore.markCollectionGap(
                                from: destructiveGapStart,
                                to: failedAt
                            )
                            try await flushActiveDrainIfRequested()
                            let ledger = try await ledgerStore.readCurrentPeriods(at: failedAt)
                            let report = report(
                                configuration: configuration,
                                identity: identity,
                                ledger: ledger,
                                collectionIssue: issue(for: error),
                                at: failedAt
                            )
                            publish(report, for: configuration)
                            return .init(report: report, retryDisposition: .terminal)
                        } catch {
                            let report = report(
                                configuration: configuration,
                                identity: identity,
                                ledger: baseline,
                                ledgerError: error,
                                at: failedAt
                            )
                            publish(report, for: configuration)
                            return .init(report: report, retryDisposition: .terminal)
                        }
                    }
                    if hasMalformedRecordGap {
                        do {
                            try await flushActiveDrainIfRequested()
                            let ledger = try await ledgerStore.readCurrentPeriods(at: failedAt)
                            let report = report(
                                configuration: configuration,
                                identity: identity,
                                ledger: ledger,
                                collectionIssue: issue(for: error),
                                at: failedAt
                            )
                            publish(report, for: configuration)
                            return .init(
                                report: report,
                                retryDisposition: retryDisposition(for: error)
                            )
                        } catch {
                            let report = report(
                                configuration: configuration,
                                identity: identity,
                                ledger: baseline,
                                ledgerError: error,
                                at: failedAt
                            )
                            publish(report, for: configuration)
                            return .init(report: report, retryDisposition: .terminal)
                        }
                    }
                    let report = report(
                        configuration: configuration,
                        identity: identity,
                        ledger: baseline,
                        collectionIssue: issue(for: error),
                        at: failedAt
                    )
                    publish(report, for: configuration)
                    return .init(
                        report: report,
                        retryDisposition: retryDisposition(for: error)
                    )
                } catch {
                    let report = report(
                        configuration: configuration,
                        identity: identity,
                        ledger: baseline,
                        collectionIssue: .transientCollectionFailure,
                        at: now()
                    )
                    publish(report, for: configuration)
                    return .init(report: report, retryDisposition: .retryable)
                }

                if batch.malformedRecordCount > 0 {
                    let gapEnd = now()
                    do {
                        try await ledgerStore.markCollectionGap(
                            from: destructiveGapStart,
                            to: gapEnd
                        )
                        hasMalformedRecordGap = true
                    } catch {
                        let report = report(
                            configuration: configuration,
                            identity: identity,
                            ledger: baseline,
                            ledgerError: error,
                            at: gapEnd
                        )
                        publish(report, for: configuration)
                        return .init(report: report, retryDisposition: .terminal)
                    }
                }

                let records = batch.records
                let mutations = records.compactMap { record in
                    makeMutation(record, profiles: configuration.profiles)
                }
                do {
                    try await ledgerStore.merge(mutations)
                } catch {
                    let mergeError = error
                    let failedAt = now()
                    let lossTimestamps = records.map(\.timestamp)
                    do {
                        try await ledgerStore.markPersistenceFailure(for: lossTimestamps)
                        try await flushActiveDrainIfRequested()
                        let ledger = try await ledgerStore.readCurrentPeriods(at: failedAt)
                        try await flushActiveDrainIfRequested()
                        let report = report(
                            configuration: configuration,
                            identity: identity,
                            ledger: ledger,
                            ledgerError: mergeError,
                            at: failedAt
                        )
                        publish(report, for: configuration)
                        return .init(report: report, retryDisposition: .terminal)
                    } catch {
                        let report = report(
                            configuration: configuration,
                            identity: identity,
                            ledger: baseline,
                            ledgerError: mergeError,
                            at: failedAt
                        )
                        publish(report, for: configuration)
                        return .init(report: report, retryDisposition: .terminal)
                    }
                }

                for record in records {
                    latestTimestamp = maxDate(latestTimestamp, record.timestamp)
                }
                processed += batch.totalRecordCount
                shortBatchReceived = batch.totalRecordCount < Self.batchSize

                if Task.isCancelled {
                    let report = reportFromBaseline(
                        configuration: configuration,
                        identity: identity,
                        ledger: baseline,
                        at: now()
                    )
                    publish(report, for: configuration)
                    return .init(report: report, retryDisposition: .terminal)
                }
                if shortBatchReceived {
                    break
                }
            }

            if shortBatchReceived {
                break
            }
        }

        let collectedAt = now()
        do {
            try await ledgerStore.markSuccessfulDrain(
                at: collectedAt,
                lastObservedRequestAt: latestTimestamp
            )
            try await flushActiveDrainIfRequested()
            let ledger = try await ledgerStore.readCurrentPeriods(at: collectedAt)
            try await flushActiveDrainIfRequested()
            let report = reportFromBaseline(
                configuration: configuration,
                identity: identity,
                ledger: ledger,
                at: collectedAt
            )
            publish(report, for: configuration)
            return .init(report: report, retryDisposition: .normal)
        } catch {
            let report = report(
                configuration: configuration,
                identity: identity,
                ledger: baseline,
                ledgerError: error,
                at: collectedAt
            )
            publish(report, for: configuration)
            return .init(report: report, retryDisposition: .terminal)
        }
    }

    private func flushActiveDrainIfRequested() async throws {
        guard flushRequestedForActiveDrain, !activeDrainDidFlush else { return }
        try await ledgerStore.flush()
        activeDrainDidFlush = true
    }

    private func startPolling(
        after result: DrainResult,
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        stopGeneration: UInt64
    ) {
        guard self.configuration == configuration,
              lifecycleStopGeneration == stopGeneration,
              pollingTask == nil,
              configuration.usageEnabled,
              configuration.proxyReady,
              !configuration.enabledProviders.isEmpty,
              result.retryDisposition != .terminal else {
            return
        }

        pollingGeneration &+= 1
        let generation = pollingGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.poll(
                configuration: configuration,
                identity: identity,
                initialDisposition: result.retryDisposition,
                generation: generation,
                stopGeneration: stopGeneration
            )
        }
        pollingTask = task
    }

    private func poll(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        initialDisposition: RetryDisposition,
        generation: UInt64,
        stopGeneration: UInt64
    ) async {
        var disposition = initialDisposition
        var retryIndex = 0

        while !Task.isCancelled {
            let delay: UInt64
            switch disposition {
            case .normal:
                delay = Self.normalPollNanoseconds
                retryIndex = 0
            case .retryable:
                delay = Self.retryNanoseconds[min(retryIndex, Self.retryNanoseconds.count - 1)]
            case .terminal:
                finishPolling(generation: generation)
                return
            }

            do {
                try await sleep(delay)
            } catch {
                finishPolling(generation: generation)
                return
            }
            guard !Task.isCancelled,
                  self.configuration == configuration,
                  lifecycleStopGeneration == stopGeneration else {
                finishPolling(generation: generation)
                return
            }

            let result = await sharedDrain(
                configuration: configuration,
                identity: identity,
                flushAfterDrain: false,
                source: .polling,
                stopGeneration: stopGeneration
            )
            disposition = result.retryDisposition
            if disposition == .retryable {
                retryIndex = min(retryIndex + 1, Self.retryNanoseconds.count - 1)
            } else if disposition == .normal {
                retryIndex = 0
            } else {
                finishPolling(generation: generation)
                return
            }
        }

        finishPolling(generation: generation)
    }

    private func finishPolling(generation: UInt64) {
        guard pollingGeneration == generation else { return }
        pollingTask = nil
    }

    private func cancelPolling() async {
        guard let task = pollingTask else { return }
        pollingTask = nil
        pollingGeneration &+= 1
        if activeDrainSource == .polling {
            reloadTask?.cancel()
        }
        task.cancel()
        await task.value
    }

    private func waitForActiveInitialization() async {
        guard let task = initializationTask,
              let generation = activeInitializationGeneration else {
            return
        }
        _ = try? await task.value
        finishInitialization(generation: generation)
    }

    private func waitForActiveLifecycleDrain() async {
        guard activeDrainSource == .lifecycle,
              let task = reloadTask,
              let generation = activeReloadGeneration else {
            return
        }
        _ = await task.value
        finishReload(generation: generation)
    }

    private func makeMutation(
        _ record: APIUsageQueueRecord,
        profiles: [APIUsageProfileDescriptor]
    ) -> APIUsageLedgerMutation? {
        switch mapper.classify(record, profiles: profiles) {
        case .ignored:
            return nil
        case let .issue(issue):
            return .issue(issue)
        case let .aggregate(input):
            let epoch = catalog.entry(
                provider: input.provider,
                model: input.model,
                serviceTier: input.effectiveServiceTier,
                variant: input.pricingVariant,
                at: input.timestamp
            )?.effectiveFrom
            return .aggregate(input, priceEpochStart: epoch)
        }
    }

    private func restoredReport(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        at: Date
    ) async -> APIUsageCollectionReport {
        guard configuration.usageEnabled else {
            return disabledReport(configuration: configuration, identity: identity, at: at)
        }

        do {
            let ledger = try await ledgerStore.readCurrentPeriods(at: at)
            var report = reportFromBaseline(
                configuration: configuration,
                identity: identity,
                ledger: ledger,
                at: at
            )
            if !configuration.proxyReady, !configuration.enabledProviders.isEmpty {
                report = adding(issue: .proxyUnavailable, to: report)
            }
            return report
        } catch {
            return report(
                configuration: configuration,
                identity: identity,
                ledger: nil,
                ledgerError: error,
                at: at
            )
        }
    }

    private func disabledReport(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        at: Date
    ) -> APIUsageCollectionReport {
        APIUsageCollectionReport(
            identity: identity,
            statesByProfileID: Dictionary(
                configuration.profiles.map { ($0.profileID, APICostUsageState.disabled) },
                uniquingKeysWith: { first, _ in first }
            ),
            collectedAt: at
        )
    }

    private func reportFromBaseline(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        ledger: APIUsageLedgerReadModel?,
        at: Date
    ) -> APIUsageCollectionReport {
        guard let ledger else {
            return APIUsageCollectionReport(
                identity: identity,
                statesByProfileID: states(
                    configuration: configuration,
                    makeState: { .loading }
                ),
                collectedAt: at
            )
        }

        return APIUsageCollectionReport(
            identity: identity,
            statesByProfileID: estimator.states(
                for: configuration.profiles,
                ledger: ledger,
                now: at
            ),
            collectedAt: at
        )
    }

    private func report(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        ledger: APIUsageLedgerReadModel?,
        collectionIssue: APICostIssue,
        at: Date
    ) -> APIUsageCollectionReport {
        let base = reportFromBaseline(
            configuration: configuration,
            identity: identity,
            ledger: ledger,
            at: at
        )
        return adding(issue: collectionIssue, to: base)
    }

    private func report(
        configuration: APIUsageCollectorConfiguration,
        identity: APIUsageCollectorIdentity,
        ledger: APIUsageLedgerReadModel?,
        ledgerError: Error,
        at: Date
    ) -> APIUsageCollectionReport {
        if let ledgerError = ledgerError as? APIUsageLedgerStoreError,
           ledgerError == .notInitialized {
            return APIUsageCollectionReport(
                identity: identity,
                statesByProfileID: states(
                    configuration: configuration,
                    makeState: { .loading }
                ),
                collectedAt: at
            )
        }

        let issue: APICostIssue
        if let ledgerError = ledgerError as? APIUsageLedgerStoreError,
           case .unsupportedSchemaVersion = ledgerError {
            issue = .unsupportedLedgerVersion
        } else {
            issue = .persistenceFailure
        }
        return report(
            configuration: configuration,
            identity: identity,
            ledger: ledger,
            collectionIssue: issue,
            at: at
        )
    }

    private func adding(
        issue: APICostIssue,
        to report: APIUsageCollectionReport
    ) -> APIUsageCollectionReport {
        APIUsageCollectionReport(
            identity: report.identity,
            statesByProfileID: report.statesByProfileID.mapValues {
                adding(issue: issue, to: $0)
            },
            collectedAt: report.collectedAt
        )
    }

    private func adding(
        issue: APICostIssue,
        to state: APICostUsageState
    ) -> APICostUsageState {
        guard let snapshot = state.snapshot else {
            return .unavailable(issue)
        }

        let day = adding(issue: issue, to: snapshot.day)
        let month = adding(issue: issue, to: snapshot.month)
        let decorated = APICostSnapshot(
            profileID: snapshot.profileID,
            provider: snapshot.provider,
            day: day,
            month: month,
            reportingTimeZoneID: snapshot.reportingTimeZoneID,
            updatedAt: snapshot.updatedAt
        )
        let issues = ordered(day.issues + month.issues)
        return .partial(decorated, issues)
    }

    private func adding(
        issue: APICostIssue,
        to snapshot: APICostPeriodSnapshot
    ) -> APICostPeriodSnapshot {
        APICostPeriodSnapshot(
            period: snapshot.period,
            estimatedUSD: snapshot.estimatedUSD,
            totalTokens: snapshot.totalTokens,
            requestCount: snapshot.requestCount,
            failedRequestCount: snapshot.failedRequestCount,
            pricedRequestCount: snapshot.pricedRequestCount,
            unpricedRequestCount: snapshot.unpricedRequestCount,
            intervalStart: snapshot.intervalStart,
            intervalEnd: snapshot.intervalEnd,
            issues: ordered(snapshot.issues + [issue])
        )
    }

    private func issue(for error: APIUsageQueueClientError) -> APICostIssue {
        switch error {
        case .managementKeyNotConfigured:
            return .managementKeyNotConfigured
        case .managementKeyRejected:
            return .managementKeyRejected
        case .managementAPINotSupported, .schemaMismatch, .invalidCount:
            return .managementAPINotSupported
        case .invalidPort, .proxyUnavailable:
            return .proxyUnavailable
        case .transientFailure:
            return .transientCollectionFailure
        }
    }

    private func retryDisposition(
        for error: APIUsageQueueClientError
    ) -> RetryDisposition {
        switch error {
        case .transientFailure, .proxyUnavailable:
            return .retryable
        case .invalidPort,
             .invalidCount,
             .managementKeyNotConfigured,
             .managementKeyRejected,
             .managementAPINotSupported,
             .schemaMismatch:
            return .terminal
        }
    }

    private func states(
        configuration: APIUsageCollectorConfiguration,
        makeState: () -> APICostUsageState
    ) -> [String: APICostUsageState] {
        Dictionary(
            configuration.profiles.map { ($0.profileID, makeState()) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func ordered(_ issues: [APICostIssue]) -> [APICostIssue] {
        APICostIssue.allCases.filter { issues.contains($0) }
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private func nextIdentity() -> APIUsageCollectorIdentity {
        reportGeneration &+= 1
        let identity = APIUsageCollectorIdentity(generation: reportGeneration)
        currentIdentity = identity
        return identity
    }

    private func publish(
        _ report: APIUsageCollectionReport,
        for configuration: APIUsageCollectorConfiguration
    ) {
        guard self.configuration == configuration else { return }
        publish(report)
    }

    private func publish(_ report: APIUsageCollectionReport) {
        latestReport = report
        reportContinuation?.yield(report)
    }

    private func removeReportContinuation(id: UUID) {
        guard reportContinuationID == id else { return }
        reportContinuation = nil
        reportContinuationID = nil
    }
}
