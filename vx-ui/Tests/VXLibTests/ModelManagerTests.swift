import Combine
import XCTest
@testable import VXLib

private final class PendingModelRequest: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // Keep the request pending until cancellation.
    override func stopLoading() {}
}

@MainActor
final class ModelManagerTests: XCTestCase {
    func testCompletedTransferShowsInstallingAndIgnoresLateProgressUntilCancelCleanup() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingModelRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let manager = ModelManager(session: session)
        let model = SpeechModel(id: "install-state-test", displayName: "Test", detail: "",
                                fileName: "install-state-test.bin", approximateSizeMB: 1,
                                downloadURL: URL(string: "https://model.invalid/test.bin")!)
        manager.download(model)
        let tasks = await session.allTasks
        let task = try XCTUnwrap(tasks.first)
        let installing = expectation(description: "transfer finished, installation pending")
        let observation = manager.$states.sink { states in
            if states[model.id] == .installing { installing.fulfill() }
        }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 100
        await fulfillment(of: [installing], timeout: 2)
        observation.cancel()
        XCTAssertEqual(manager.states[model.id], .installing)

        // Delayed transfer notifications must not replace the installation state.
        let delivered = expectation(description: "late progress delivered")
        task.progress.completedUnitCount = 99
        DispatchQueue.main.async { delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(manager.states[model.id], .installing)
        manager.refreshInstalledStates()
        XCTAssertEqual(manager.states[model.id], .installing)
        manager.download(model)
        XCTAssertEqual(manager.states[model.id], .installing)

        manager.cancelDownload(for: model)
        XCTAssertEqual(manager.states[model.id], .cancelling)
        let cleaned = expectation(description: "installation cancellation cleanup")
        let cleanupObservation = manager.$states.sink { states in
            if states[model.id] == .notInstalled { cleaned.fulfill() }
        }
        await fulfillment(of: [cleaned], timeout: 5)
        cleanupObservation.cancel()
        XCTAssertEqual(manager.states[model.id], .notInstalled)
    }

    func testCancelKeepsRetryUnavailableUntilCleanupThenAllowsAnotherDownload() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingModelRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let manager = ModelManager(session: session)
        let model = SpeechModel(id: "cancel-test", displayName: "Test", detail: "",
                                fileName: "cancel-test.bin", approximateSizeMB: 1,
                                downloadURL: URL(string: "https://model.invalid/test.bin")!)
        // Repeat after cleanup to prove the old job no longer blocks a retry.
        for attempt in 1...2 {
            manager.download(model)
            XCTAssertTrue(manager.states[model.id]?.isDownloading == true)
            manager.cancelDownload(for: model)
            XCTAssertEqual(manager.states[model.id], .cancelling)
            manager.download(model)
            XCTAssertEqual(manager.states[model.id], .cancelling)
            let cleaned = expectation(description: "cancel cleanup \(attempt)")
            let observation = manager.$states.sink { states in
                if states[model.id] == .notInstalled { cleaned.fulfill() }
            }
            await fulfillment(of: [cleaned], timeout: 5)
            observation.cancel()
            XCTAssertEqual(manager.states[model.id], .notInstalled)
        }
    }
}
