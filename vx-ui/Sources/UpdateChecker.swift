import AppKit
import Foundation

struct UpdateManifest: Decodable {
    let version: String
    let url: URL
}

struct AvailableUpdate {
    let version: String
    let downloadURL: URL
}

@MainActor
final class UpdateChecker {
    private let manifestURL = DistributionConfig.updateManifestURL

    private(set) var availableUpdate: AvailableUpdate?
    var onUpdateAvailable: ((AvailableUpdate) -> Void)?
    var onNoUpdateAvailable: (() -> Void)?
    var onCheckFailed: (() -> Void)?
    var onProgress: ((Double) -> Void)?

    private var checkTask: Task<Void, Never>?

    func checkForUpdates() {
        checkTask?.cancel()
        checkTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: manifestURL)
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

                guard isNewer(manifest.version) else {
                    vxLog("[updater/check] Up to date (current: \(currentVersion), remote: \(manifest.version))")
                    onNoUpdateAvailable?()
                    return
                }

                vxLog("[updater/check] Update available: \(manifest.version) (current: \(currentVersion))")
                let update = AvailableUpdate(version: manifest.version, downloadURL: manifest.url)
                availableUpdate = update
                onUpdateAvailable?(update)
            } catch {
                vxLog("[updater/check] Failed to fetch manifest: \(error.localizedDescription)")
                onCheckFailed?()
            }
        }
    }

    func installUpdate(_ update: AvailableUpdate) {
        Task { await performInstall(update) }
    }

    private func performInstall(_ update: AvailableUpdate) async {
        vxLog("[updater/install] Downloading \(update.version) from \(update.downloadURL)")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-update-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Download zip with progress reporting
            let zipURL = tempDir.appendingPathComponent("vx.zip")
            let progressDelegate = DownloadProgressDelegate { [weak self] fraction in
                self?.onProgress?(fraction)
            }
            let (downloadedURL, _) = try await URLSession.shared.download(from: update.downloadURL, delegate: progressDelegate)
            try FileManager.default.moveItem(at: downloadedURL, to: zipURL)

            // Verify the download against the embedded release key BEFORE extracting
            // or running anything. The detached signature lives next to the artifact
            // (vx.zip -> vx.zip.sig), so every install path — normal update and
            // version-history rollback alike — is verified the same way. Fail closed:
            // a missing or bad signature aborts the install.
            let zipData = try Data(contentsOf: zipURL)
            let signatureURL = update.downloadURL.appendingPathExtension("sig")
            let signature: String
            do {
                let (sigData, _) = try await URLSession.shared.data(from: signatureURL)
                signature = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                vxLog("[updater/install] Could not fetch signature (\(signatureURL.lastPathComponent)) — refusing to install \(update.version)")
                onCheckFailed?()
                return
            }
            guard DistributionConfig.verifyUpdateSignature(signature, of: zipData) else {
                vxLog("[updater/install] Signature verification FAILED — refusing to install \(update.version)")
                onCheckFailed?()
                return
            }
            vxLog("[updater/install] Signature verified for \(update.version)")

            vxLog("[updater/install] Download complete, extracting...")

            // Unzip via ditto (preserves resource forks, consistent with how we package)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", zipURL.path, tempDir.path]
            try unzip.run()
            unzip.waitUntilExit()

            guard unzip.terminationStatus == 0 else {
                vxLog("[updater/install] Extraction failed (exit \(unzip.terminationStatus))")
                return
            }

            let newAppPath = tempDir.appendingPathComponent("vx.app").path
            guard FileManager.default.fileExists(atPath: newAppPath) else {
                vxLog("[updater/install] vx.app not found in extracted zip")
                return
            }

            let installPath = Bundle.main.bundleURL.path
            guard installPath.hasSuffix(".app") else {
                vxLog("[updater/install] Not running as .app bundle (dev mode?) — skipping swap")
                return
            }

            vxLog("[updater/install] Swapping: \(installPath)")

            // Write a detached shell script that waits for us to quit, swaps the bundle, relaunches
            let scriptPath = tempDir.appendingPathComponent("swap.sh").path
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            #!/bin/bash
            set -e
            while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
            sleep 0.3
            rm -rf \(shellEscape(installPath))
            cp -r \(shellEscape(newAppPath)) \(shellEscape(installPath))
            xattr -cr \(shellEscape(installPath)) 2>/dev/null || true
            open \(shellEscape(installPath))
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/bash")
            swap.arguments = [scriptPath]
            try swap.run()

            vxLog("[updater/install] Swap script launched — quitting to apply update")
            NSApp.terminate(nil)
        } catch {
            vxLog("[updater/install] Failed: \(error.localizedDescription)")
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func isNewer(_ remote: String) -> Bool {
        remote.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    // Single-quote escaping for shell paths (handles spaces, parens, etc.)
    private func shellEscape(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.handler(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
