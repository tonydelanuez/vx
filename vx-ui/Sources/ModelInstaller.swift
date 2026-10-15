import Foundation
import CryptoKit

/// Installs downloads in staging, then publishes a complete model atomically.
/// Runs off the main queue because archive hashing and extraction can take seconds.
enum ModelInstaller {
    static func install(_ model: SpeechModel, from download: URL, into directory: URL,
                        isCancelled: () -> Bool = { false }) throws {
        if isCancelled() { throw CancellationError() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".install-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent(model.fileName)

        if let expectedHash = model.archiveSHA256 {
            guard try sha256(download, isCancelled: isCancelled) == expectedHash else {
                throw InstallError.invalid("Model download checksum does not match. Please retry the download.")
            }
            // Extract only catalog filenames from the checksum-verified archive.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xjf", download.path, "-C", staging.path]
                + SpeechModel.parakeetFiles.map { "\(model.fileName)/\($0)" }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            while process.isRunning {
                if isCancelled() {
                    process.terminate()
                    process.waitUntilExit()
                    throw CancellationError()
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw InstallError.invalid("Cannot extract the Parakeet model. Please retry the download.")
            }
        } else {
            try fm.copyItem(at: download, to: candidate)
        }
        guard model.isComplete(at: candidate) else {
            throw InstallError.invalid("The downloaded model is incomplete. Please retry the download.")
        }
        if isCancelled() { throw CancellationError() }
        let destination = directory.appendingPathComponent(model.fileName)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: candidate)
        } else {
            try fm.moveItem(at: candidate, to: destination)
        }
    }

    static func sha256(_ url: URL, isCancelled: () -> Bool = { false }) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum InstallError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }
}
