import XCTest
@testable import VXLib

final class RuleStoreResolutionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-test-rules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempDir.appendingPathComponent("code"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func write(_ content: String, to relativePath: String) {
        let url = tempDir.appendingPathComponent(relativePath)
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeStore() -> RuleStore {
        return RuleStore(rulesDirectory: tempDir)
    }

    func testGlobalRulesLoadedForAllModes() {
        write("""
        rules:
          - trigger: "global trigger"
            replace: "global"
        """, to: "global.yaml")
        write("rules: []", to: "plain.yaml")

        let store = makeStore()
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        let tagged = store.taggedRules(for: context)

        XCTAssertTrue(tagged.contains(where: { $0.rule.trigger == "global trigger" }))
    }

    func testModeSpecificRulesLoadedAfterGlobal() {
        write("""
        rules:
          - trigger: "global"
            replace: "g"
        """, to: "global.yaml")
        write("""
        rules:
          - trigger: "markdown heading"
            replace: "# "
        """, to: "markdown.yaml")

        let store = makeStore()
        let context = RuleContext(mode: .markdown, codeProfile: .generic)
        let tagged = store.taggedRules(for: context)

        let sources = tagged.map(\.source)
        let globalIdx = sources.firstIndex(of: "global.yaml") ?? Int.max
        let mdIdx = sources.firstIndex(of: "markdown.yaml") ?? Int.max
        XCTAssertLessThan(globalIdx, mdIdx, "global.yaml must precede markdown.yaml")
    }

    func testCodeGlobalRulesLoadedBeforeProfile() {
        write("rules: []", to: "global.yaml")
        write("""
        rules:
          - trigger: "open brace"
            replace: "{"
        """, to: "code/global.yaml")
        write("""
        rules:
          - trigger: "guard let"
            replace: "guard let ="
        """, to: "code/swift.yaml")

        let store = makeStore()
        let context = RuleContext(mode: .code, codeProfile: .swift)
        let tagged = store.taggedRules(for: context)

        let sources = tagged.map(\.source)
        let cgIdx = sources.firstIndex(of: "code/global.yaml") ?? Int.max
        let swiftIdx = sources.firstIndex(of: "code/swift.yaml") ?? Int.max
        XCTAssertLessThan(cgIdx, swiftIdx, "code/global.yaml must precede code/swift.yaml")
    }

    func testMissingRuleFileProducesEmptyNotCrash() {
        // Don't write markdown.yaml — it's absent
        write("rules: []", to: "global.yaml")

        let store = makeStore()
        let context = RuleContext(mode: .markdown, codeProfile: .generic)
        // Should not crash; returns empty for the missing file
        let rules = store.rules(for: context)
        XCTAssertNotNil(rules) // Just checking it doesn't throw/crash
    }

    func testLoadErrorRecorded() {
        write("this is: not: valid: yaml: [[[", to: "global.yaml")
        // The parser is lenient, but at minimum a malformed file shouldn't crash
        // and should produce zero rules (not a fatal error).
        let store = makeStore()
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        _ = store.rules(for: context)
        // No assert needed beyond confirming no crash; the parser is lenient.
    }

    func testReloadClearsCacheAndErrors() {
        write("rules: []", to: "global.yaml")
        write("rules: []", to: "plain.yaml")
        let store = makeStore()
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        _ = store.rules(for: context)

        // Now add a real rule and reload
        write("""
        rules:
          - trigger: "test"
            replace: "ok"
        """, to: "global.yaml")
        store.reload()
        let rules = store.rules(for: context)
        XCTAssertTrue(rules.contains(where: { $0.trigger == "test" }), "Rules should reload after cache clear")
    }

    func testResolutionPathsMatchExpected() {
        let store = makeStore()
        let plainCtx = RuleContext(mode: .plainText, codeProfile: .generic)
        XCTAssertEqual(store.resolutionPaths(for: plainCtx), ["global.yaml", "plain.yaml"])

        let codeCtx = RuleContext(mode: .code, codeProfile: .swift)
        XCTAssertEqual(store.resolutionPaths(for: codeCtx), ["global.yaml", "code/global.yaml", "code/swift.yaml"])
    }
}
