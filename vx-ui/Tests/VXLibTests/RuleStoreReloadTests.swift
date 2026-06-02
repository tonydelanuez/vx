import XCTest
@testable import VXLib

final class RuleStoreReloadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-reload-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "rules: []".write(to: dir.appendingPathComponent("plain.yaml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeGlobal(trigger: String, replace: String, mtime: Date? = nil) throws {
        let yaml = "rules:\n  - trigger: \"\(trigger)\"\n    replace: \"\(replace)\"\n"
        let url = dir.appendingPathComponent("global.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    private let plainContext = RuleContext(mode: .plainText, codeProfile: .generic)

    func testEditedRuleFileIsPickedUpWithoutExplicitReload() throws {
        try writeGlobal(trigger: "foo", replace: "bar")
        let store = RuleStore(rulesDirectory: dir)
        XCTAssertEqual(store.rules(for: plainContext).map(\.trigger), ["foo"])

        // Edit the file and advance its mtime; do NOT call reload().
        try writeGlobal(trigger: "baz", replace: "qux", mtime: Date().addingTimeInterval(10))
        XCTAssertEqual(store.rules(for: plainContext).map(\.trigger), ["baz"],
                       "edited rule file should be picked up automatically")
    }

    func testUnchangedFileServesFromCache() throws {
        try writeGlobal(trigger: "foo", replace: "bar", mtime: Date())
        let store = RuleStore(rulesDirectory: dir)
        _ = store.rules(for: plainContext)
        // Same mtime, same content → still resolves correctly (cache hit path).
        XCTAssertEqual(store.rules(for: plainContext).map(\.trigger), ["foo"])
    }
}
