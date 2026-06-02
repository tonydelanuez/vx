import CryptoKit
import Foundation

/// Single source of truth for the app's distribution and auto-update endpoints.
///
/// A fork that ships its own builds changes the values here (and its update
/// signing keypair) and points its release tooling at the same Gist manifest
/// and releases repo.
enum DistributionConfig {
    /// GitHub "owner/repo" hosting the published release assets (vx.zip).
    static let releasesRepo = "tonydelanuez/vx"

    /// Ed25519 public key (raw 32 bytes) used to verify downloaded update
    /// artifacts. The matching private key signs `vx.zip` at release time and is
    /// never committed. A fork replaces this with its own public key.
    static let updatePublicKey = Data(base64Encoded: "4XbX3ZcqeATWrELqzVECsP2i9BiBbZGPwZeM+w4ZkD0=")!

    /// Verifies a base64-encoded Ed25519 signature against `data` using `publicKey`
    /// (defaults to the embedded release key). Returns false on any malformed input.
    static func verifyUpdateSignature(_ signatureBase64: String,
                                      of data: Data,
                                      publicKey: Data = updatePublicKey) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    /// Raw Gist URL holding the auto-update manifest: {"version": ..., "url": ...}.
    static let updateManifestURL = URL(
        string: "https://gist.githubusercontent.com/tonydelanuez/c2de9ca8e5a0f7be1a1f4b1e5a6c0884/raw/vx-manifest.json"
    )!

    /// Download URL for a release tag's vx.zip asset.
    static func releaseDownloadURL(tag: String) -> URL {
        URL(string: "https://github.com/\(releasesRepo)/releases/download/\(tag)/vx.zip")!
    }

    /// GitHub API endpoint listing published releases (version history).
    static var releasesAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(releasesRepo)/releases")!
    }
}
