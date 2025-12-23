import CloudKit
import Foundation

#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

public struct CloudKitProgress: Sendable {
    public let bookId: String
    public let locator: BookLocator
    public let timestamp: Double
    public let deviceId: String
}

public enum FetchProgressResult: Sendable {
    case success(CloudKitProgress)
    case noRecord
    case networkError
}

@globalActor
public actor CloudKitSyncActor {
    public static let shared = CloudKitSyncActor()

    private static let containerIdentifier = "iCloud.com.kyonifer.SilveranReader"

    private let container: CKContainer?
    private let database: CKDatabase?
    private let recordType = "BookProgress"

    private var observers: (@Sendable @MainActor () -> Void)?
    public private(set) var connectionStatus: ConnectionStatus = .disconnected

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        #if os(macOS)
        // On macOS VMs, CloudKit crashes when trying to initialize CKContainer
        var isVM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.hv_vmm_present", &isVM, &size, nil, 0) == 0, isVM == 1 {
            debugLog("[CloudKitSyncActor] Running in VM - CloudKit sync disabled")
            container = nil
            database = nil
            return
        }
        #endif

        container = CKContainer(identifier: Self.containerIdentifier)
        database = container?.privateCloudDatabase
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        Task {
            await checkAccountStatus()
        }
    }

    public func request_notify(callback: @Sendable @MainActor @escaping () -> Void) {
        self.observers = callback
    }

    private func updateConnectionStatus(_ status: ConnectionStatus) async {
        debugLog("[CloudKitSyncActor] updateConnectionStatus: \(connectionStatus) -> \(status)")
        connectionStatus = status
        await observers?()
    }

    private func checkAccountStatus() async {
        guard let container = container else {
            await updateConnectionStatus(.error("iCloud not available"))
            return
        }

        do {
            let status = try await container.accountStatus()
            switch status {
                case .available:
                    await updateConnectionStatus(.connected)
                case .noAccount:
                    await updateConnectionStatus(.error("No iCloud account"))
                case .restricted:
                    await updateConnectionStatus(.error("iCloud restricted"))
                case .couldNotDetermine:
                    await updateConnectionStatus(.error("Could not determine iCloud status"))
                case .temporarilyUnavailable:
                    await updateConnectionStatus(.error("iCloud temporarily unavailable"))
                @unknown default:
                    await updateConnectionStatus(.error("Unknown iCloud status"))
            }
        } catch {
            debugLog("[CloudKitSyncActor] checkAccountStatus failed: \(error)")
            await updateConnectionStatus(.error(error.localizedDescription))
        }
    }

    public func sendProgressToCloudKit(
        bookId: String,
        locator: BookLocator,
        timestamp: Double
    ) async -> HTTPResult {
        debugLog(
            "[CloudKitSyncActor] sendProgressToCloudKit: bookId=\(bookId), timestamp=\(timestamp)"
        )

        guard let database = database else {
            debugLog("[CloudKitSyncActor] sendProgressToCloudKit: iCloud not available")
            return .noConnection
        }

        if connectionStatus != .connected {
            await checkAccountStatus()
        }
        guard connectionStatus == .connected else {
            debugLog("[CloudKitSyncActor] sendProgressToCloudKit: not connected")
            return .noConnection
        }

        do {
            let locatorJson = try encoder.encode(locator)
            guard let locatorString = String(data: locatorJson, encoding: .utf8) else {
                debugLog("[CloudKitSyncActor] sendProgressToCloudKit: failed to encode locator")
                return .failure
            }

            let recordID = CKRecord.ID(recordName: bookId)
            let record = CKRecord(recordType: recordType, recordID: recordID)

            record["bookId"] = bookId
            record["locatorJson"] = locatorString
            record["timestamp"] = timestamp
            record["deviceId"] = await deviceIdentifier()

            let operation = CKModifyRecordsOperation(
                recordsToSave: [record],
                recordIDsToDelete: nil
            )
            operation.savePolicy = .allKeys
            operation.qualityOfService = .userInitiated

            return try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                        case .success:
                            debugLog(
                                "[CloudKitSyncActor] sendProgressToCloudKit: saved record \(bookId)"
                            )
                            continuation.resume(returning: .success)
                        case .failure(let error):
                            debugLog("[CloudKitSyncActor] sendProgressToCloudKit: error \(error)")
                            if let ckError = error as? CKError,
                                ckError.code == .networkUnavailable
                                    || ckError.code == .networkFailure
                            {
                                continuation.resume(returning: .noConnection)
                            } else {
                                continuation.resume(returning: .failure)
                            }
                    }
                }
                database.add(operation)
            }

        } catch let error as CKError {
            debugLog(
                "[CloudKitSyncActor] sendProgressToCloudKit: CKError \(error.code.rawValue) - \(error.localizedDescription)"
            )
            if error.code == .networkUnavailable || error.code == .networkFailure {
                return .noConnection
            }
            return .failure
        } catch {
            debugLog("[CloudKitSyncActor] sendProgressToCloudKit: error \(error)")
            return .failure
        }
    }

    public func fetchProgress(for bookId: String) async -> FetchProgressResult {
        debugLog("[CloudKitSyncActor] fetchProgress: bookId=\(bookId)")

        guard let database = database else {
            debugLog("[CloudKitSyncActor] fetchProgress: iCloud not available")
            return .networkError
        }

        if connectionStatus != .connected {
            await checkAccountStatus()
        }
        guard connectionStatus == .connected else {
            debugLog("[CloudKitSyncActor] fetchProgress: not connected")
            return .networkError
        }

        do {
            let recordID = CKRecord.ID(recordName: bookId)
            let record = try await database.record(for: recordID)
            if let progress = parseRecord(record) {
                return .success(progress)
            }
            return .noRecord
        } catch CKError.unknownItem {
            debugLog("[CloudKitSyncActor] fetchProgress: no record found for \(bookId)")
            return .noRecord
        } catch let error as CKError
            where error.code == .networkUnavailable || error.code == .networkFailure
        {
            debugLog("[CloudKitSyncActor] fetchProgress: network error \(error)")
            return .networkError
        } catch {
            debugLog("[CloudKitSyncActor] fetchProgress: error \(error)")
            return .networkError
        }
    }

    public func fetchAllProgress() async -> [String: CloudKitProgress]? {
        debugLog("[CloudKitSyncActor] fetchAllProgress")

        guard let database = database else {
            debugLog("[CloudKitSyncActor] fetchAllProgress: iCloud not available")
            return nil
        }

        if connectionStatus != .connected {
            await checkAccountStatus()
        }
        guard connectionStatus == .connected else {
            debugLog("[CloudKitSyncActor] fetchAllProgress: not connected")
            return nil
        }

        do {
            let predicate = NSPredicate(format: "timestamp > %f", 0.0)
            let query = CKQuery(recordType: recordType, predicate: predicate)

            var progressMap: [String: CloudKitProgress] = [:]
            var cursor: CKQueryOperation.Cursor?

            repeat {
                let (results, nextCursor):
                    ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)

                if let existingCursor = cursor {
                    (results, nextCursor) = try await database.records(
                        continuingMatchFrom: existingCursor,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                } else {
                    (results, nextCursor) = try await database.records(
                        matching: query,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                }

                for (_, result) in results {
                    switch result {
                        case .success(let record):
                            if let progress = parseRecord(record) {
                                progressMap[progress.bookId] = progress
                            }
                        case .failure(let error):
                            debugLog("[CloudKitSyncActor] fetchAllProgress: record error \(error)")
                    }
                }

                cursor = nextCursor
            } while cursor != nil

            debugLog("[CloudKitSyncActor] fetchAllProgress: found \(progressMap.count) records")
            return progressMap

        } catch {
            debugLog("[CloudKitSyncActor] fetchAllProgress: error \(error)")
            return nil
        }
    }

    public func recordCount() async -> Int {
        guard let database = database else {
            debugLog("[CloudKitSyncActor] recordCount: iCloud not available")
            return 0
        }

        if connectionStatus != .connected {
            await checkAccountStatus()
        }
        guard connectionStatus == .connected else {
            debugLog("[CloudKitSyncActor] recordCount: not connected, returning 0")
            return 0
        }

        do {
            let predicate = NSPredicate(format: "timestamp > %f", 0.0)
            let query = CKQuery(recordType: recordType, predicate: predicate)

            var count = 0
            var cursor: CKQueryOperation.Cursor?

            repeat {
                let (results, nextCursor):
                    ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)

                if let existingCursor = cursor {
                    (results, nextCursor) = try await database.records(
                        continuingMatchFrom: existingCursor,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                } else {
                    (results, nextCursor) = try await database.records(
                        matching: query,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                }

                count += results.count
                cursor = nextCursor
            } while cursor != nil

            debugLog("[CloudKitSyncActor] recordCount: \(count) records")
            return count
        } catch {
            debugLog("[CloudKitSyncActor] recordCount: error \(error)")
            return 0
        }
    }

    public func deleteAllRecords() async -> Bool {
        debugLog("[CloudKitSyncActor] deleteAllRecords")

        guard let database = database else {
            debugLog("[CloudKitSyncActor] deleteAllRecords: iCloud not available")
            return false
        }

        if connectionStatus != .connected {
            await checkAccountStatus()
        }
        guard connectionStatus == .connected else {
            debugLog("[CloudKitSyncActor] deleteAllRecords: not connected")
            return false
        }

        do {
            let predicate = NSPredicate(format: "timestamp > %f", 0.0)
            let query = CKQuery(recordType: recordType, predicate: predicate)

            var allRecordIDs: [CKRecord.ID] = []
            var cursor: CKQueryOperation.Cursor?

            repeat {
                let (results, nextCursor):
                    ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)

                if let existingCursor = cursor {
                    (results, nextCursor) = try await database.records(
                        continuingMatchFrom: existingCursor,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                } else {
                    (results, nextCursor) = try await database.records(
                        matching: query,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                }

                let recordIDs = results.compactMap { (id, result) -> CKRecord.ID? in
                    switch result {
                        case .success:
                            return id
                        case .failure:
                            return nil
                    }
                }
                allRecordIDs.append(contentsOf: recordIDs)
                cursor = nextCursor
            } while cursor != nil

            if allRecordIDs.isEmpty {
                debugLog("[CloudKitSyncActor] deleteAllRecords: no records to delete")
                return true
            }

            let operation = CKModifyRecordsOperation(
                recordsToSave: nil,
                recordIDsToDelete: allRecordIDs
            )
            operation.savePolicy = .allKeys

            return try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                        case .success:
                            debugLog(
                                "[CloudKitSyncActor] deleteAllRecords: deleted \(allRecordIDs.count) records"
                            )
                            continuation.resume(returning: true)
                        case .failure(let error):
                            debugLog("[CloudKitSyncActor] deleteAllRecords: error \(error)")
                            continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }

        } catch {
            debugLog("[CloudKitSyncActor] deleteAllRecords: error \(error)")
            return false
        }
    }

    public func deleteProgress(for bookId: String) async -> Bool {
        debugLog("[CloudKitSyncActor] deleteProgress: bookId=\(bookId)")

        guard let database = database else {
            debugLog("[CloudKitSyncActor] deleteProgress: iCloud not available")
            return false
        }

        if connectionStatus != .connected {
            await checkAccountStatus()
        }
        guard connectionStatus == .connected else {
            debugLog("[CloudKitSyncActor] deleteProgress: not connected")
            return false
        }

        do {
            let recordID = CKRecord.ID(recordName: bookId)
            try await database.deleteRecord(withID: recordID)
            debugLog("[CloudKitSyncActor] deleteProgress: deleted \(bookId)")
            return true
        } catch CKError.unknownItem {
            debugLog("[CloudKitSyncActor] deleteProgress: no record found for \(bookId)")
            return true
        } catch {
            debugLog("[CloudKitSyncActor] deleteProgress: error \(error)")
            return false
        }
    }

    public func refreshConnectionStatus() async {
        await checkAccountStatus()
    }

    private func parseRecord(_ record: CKRecord) -> CloudKitProgress? {
        guard let bookId = record["bookId"] as? String,
            let locatorString = record["locatorJson"] as? String,
            let timestamp = record["timestamp"] as? Double,
            let locatorData = locatorString.data(using: .utf8),
            let locator = try? decoder.decode(BookLocator.self, from: locatorData)
        else {
            debugLog(
                "[CloudKitSyncActor] parseRecord: failed to parse record \(record.recordID.recordName)"
            )
            return nil
        }

        let deviceId = record["deviceId"] as? String ?? "unknown"

        return CloudKitProgress(
            bookId: bookId,
            locator: locator,
            timestamp: timestamp,
            deviceId: deviceId
        )
    }

    @MainActor
    private func deviceIdentifier() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(watchOS)
        return WKInterfaceDevice.current().name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown"
        #endif
    }
}
