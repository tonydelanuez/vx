import XCTest
import CryptoKit
@testable import VXLib

/// Verifies the Ed25519 update-signature check used before an auto-update is
/// installed. The verifier must accept only signatures produced by the holder of
/// the matching private key, over the exact bytes that were downloaded.
final class UpdateSignatureTests: XCTestCase {

    private func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) -> String {
        // Force-try is fine in tests: CryptoKit signing of in-memory data does not fail in practice.
        try! key.signature(for: data).base64EncodedString()
    }

    func testAcceptsSignatureFromMatchingKey() {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("vx-1.2.3.zip contents".utf8)
        let sig = sign(payload, with: key)

        XCTAssertTrue(
            DistributionConfig.verifyUpdateSignature(sig, of: payload, publicKey: key.publicKey.rawRepresentation)
        )
    }

    func testRejectsTamperedPayload() {
        let key = Curve25519.Signing.PrivateKey()
        let sig = sign(Data("original".utf8), with: key)

        XCTAssertFalse(
            DistributionConfig.verifyUpdateSignature(sig, of: Data("tampered".utf8), publicKey: key.publicKey.rawRepresentation)
        )
    }

    func testRejectsSignatureFromDifferentKey() {
        let signer = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let sig = sign(payload, with: signer)

        // Verifying against a key that did not produce the signature must fail.
        XCTAssertFalse(
            DistributionConfig.verifyUpdateSignature(sig, of: payload, publicKey: other.publicKey.rawRepresentation)
        )
    }

    func testRejectsMalformedSignature() {
        let payload = Data("payload".utf8)
        XCTAssertFalse(
            DistributionConfig.verifyUpdateSignature("not valid base64 !!!", of: payload, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        )
    }

    func testEmbeddedPublicKeyIsValidEd25519Key() {
        // A typo in the embedded base64 would otherwise only surface at runtime.
        XCTAssertEqual(DistributionConfig.updatePublicKey.count, 32)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: DistributionConfig.updatePublicKey))
    }
}
