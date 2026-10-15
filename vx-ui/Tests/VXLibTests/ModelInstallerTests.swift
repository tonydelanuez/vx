import XCTest
@testable import VXLib

final class ModelInstallerTests: XCTestCase {
    private var root: URL!
    private var destination: URL { root.appendingPathComponent("installed") }
    private var parakeet: SpeechModel { SpeechModel.find(id: "parakeet-tdt-0.6b-v3-int8")! }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func archive(files: [String], model: SpeechModel? = nil) throws -> URL {
        let model = model ?? parakeet
        let source = root.appendingPathComponent(model.fileName)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for file in files { try Data("test weights".utf8).write(to: source.appendingPathComponent(file)) }
        let archive = root.appendingPathComponent("model.tar.bz2")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cjf", archive.path, "-C", root.path, model.fileName]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    func testParakeetInstallsOnlyWhenAllFilesArePresent() throws {
        let models = SpeechModel.catalog.filter(\.isParakeet)
        XCTAssertEqual(models.count, 2)
        for var model in models {
            let download = try archive(files: SpeechModel.parakeetFiles, model: model)
            model.archiveSHA256 = try ModelInstaller.sha256(download)
            try ModelInstaller.install(model, from: download, into: destination)
            XCTAssertTrue(model.isComplete(at: destination.appendingPathComponent(model.fileName)))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), Set(models.map(\.fileName)))
    }

    func testChecksumFailurePreservesInstalledModel() throws {
        let download = try archive(files: SpeechModel.parakeetFiles)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent(parakeet.fileName)
        try FileManager.default.copyItem(at: root.appendingPathComponent(parakeet.fileName), to: original)
        XCTAssertThrowsError(try ModelInstaller.install(parakeet, from: download, into: destination))
        XCTAssertTrue(parakeet.isComplete(at: original))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [parakeet.fileName])
    }

    func testIncompleteArchiveDoesNotPublishModel() throws {
        var model = parakeet
        let download = try archive(files: ["encoder.int8.onnx"])
        model.archiveSHA256 = try ModelInstaller.sha256(download)
        XCTAssertThrowsError(try ModelInstaller.install(model, from: download, into: destination))
        XCTAssertFalse(model.isComplete(at: destination.appendingPathComponent(model.fileName)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testWhisperInstallAndReplacementKeepExistingFilename() throws {
        let model = SpeechModel.defaultModel
        let download = root.appendingPathComponent("download.bin")
        try Data("first model".utf8).write(to: download)
        try ModelInstaller.install(model, from: download, into: destination)
        try Data("replacement model".utf8).write(to: download)
        try ModelInstaller.install(model, from: download, into: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(model.fileName)), Data("replacement model".utf8))
    }

    func testCancelledInstallLeavesNoModel() throws {
        let download = root.appendingPathComponent("download.bin")
        try Data("test weights".utf8).write(to: download)
        XCTAssertThrowsError(try ModelInstaller.install(SpeechModel.defaultModel, from: download, into: destination, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellationDuringChecksumStopsInstallationAndPreservesExistingModel() throws {
        var model = parakeet
        let download = try archive(files: SpeechModel.parakeetFiles)
        model.archiveSHA256 = try ModelInstaller.sha256(download)
        let existing = destination.appendingPathComponent(model.fileName)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let original = Data("existing weights".utf8)
        try original.write(to: existing.appendingPathComponent("encoder.int8.onnx"))
        var checks = 0
        XCTAssertThrowsError(try ModelInstaller.install(model, from: download, into: destination,
            isCancelled: {
                checks += 1
                // Cancel after installation starts and the first checksum block is read.
                return checks >= 3
            })) { error in
                XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("encoder.int8.onnx")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [model.fileName])
    }

    func testModelSelectionPersistsAcrossEnginesWithoutChangingWhisperIDs() throws {
        XCTAssertEqual(Array(SpeechModel.catalog.prefix(3).map(\.id)), ["tiny.en", "base.en", "small.en"])
        let suite = TestDefaults.makeSuite()
        defer { TestDefaults.destroy(suite.name) }
        for model in SpeechModel.catalog {
            AppState(defaults: suite.defaults).selectedModelName = model.id
            let reloaded = AppState(defaults: suite.defaults)
            XCTAssertEqual(reloaded.selectedModelName, model.id)
            XCTAssertEqual(reloaded.modelURL.lastPathComponent, model.fileName)
        }
    }
}
