import XCTest
@testable import VXLib

final class DictationContextResolverTests: XCTestCase {

    /// Builds a resolver whose detection seam returns a fixed context, ignoring inputs.
    private func resolver(detecting context: AppContext) -> DictationContextResolver {
        var r = DictationContextResolver()
        r.detect = { _, _ in context }
        return r
    }

    func testUsesManualSelectionWhenAutoDetectOff() {
        let r = resolver(detecting: .email)  // would match, but auto-detect is off
        let result = r.resolve(autoDetect: false, bundleID: "com.apple.mail", pid: 1,
                               manualMode: .code, manualProfile: .swift)
        XCTAssertNil(result.detectedContext)
        XCTAssertEqual(result.mode, .code)
        XCTAssertEqual(result.codeProfile, .swift)
    }

    func testUsesManualSelectionWhenBundleIDMissing() {
        let r = resolver(detecting: .email)
        let result = r.resolve(autoDetect: true, bundleID: nil, pid: 0,
                               manualMode: .markdown, manualProfile: .generic)
        XCTAssertNil(result.detectedContext)
        XCTAssertEqual(result.mode, .markdown)
    }

    func testUsesDetectedContextWhenAutoDetectMatches() {
        let r = resolver(detecting: .code(.python))
        let result = r.resolve(autoDetect: true, bundleID: "com.jetbrains.pycharm", pid: 7,
                               manualMode: .plainText, manualProfile: .generic)
        if case .code(.python)? = result.detectedContext {} else {
            return XCTFail("expected detected .code(.python)")
        }
        XCTAssertEqual(result.mode, .code)
        XCTAssertEqual(result.codeProfile, .python)
    }

    func testGeneralMatchFallsBackToManualSelection() {
        let r = resolver(detecting: .general)  // no match
        let result = r.resolve(autoDetect: true, bundleID: "com.unknown.app", pid: 3,
                               manualMode: .email, manualProfile: .generic)
        XCTAssertNil(result.detectedContext)
        XCTAssertEqual(result.mode, .email)
    }
}
