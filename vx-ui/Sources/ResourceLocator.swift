import Foundation

/*
 Bundled Resource Setup
 ----------------------
 - Add the Whisper model files (e.g. `ggml-tiny.en.bin`) under `vx-ui/Resources/Models`
   and ensure the directory is included in the macOS target’s `Copy Bundle Resources`
   phase so they end up inside `vx.app/Contents/Resources/Models`.
 - Add the backend executable (`vx-rs`) under `vx-ui/Resources/Backend` and ensure the
   entry is also copied into the bundle with the execute bit preserved.
 - `swift run` looks for the same files relative to the repository (`Resources/…`) so
   you can iterate without packaging, while packaged builds resolve via `Bundle.main`.
 */

public enum ResourceLocator {
    public static let defaultModelName = "ggml-tiny.en"
    private static let backendExecutableName = "vx-rs"
    private static let modelExtension = "bin"
    private static let backendSubdirectory = "Backend"
    private static let modelSubdirectory = "Models"

    private static var resourceBundle: Bundle { .main }

    private static var cachedBackendURL: URL?
    private static var cachedModelURL: URL?

    public static func backendExecutableURL() -> URL {
        if let cachedBackendURL, FileManager.default.isExecutableFile(atPath: cachedBackendURL.path) {
            return cachedBackendURL
        }

        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["VX_BACKEND_PATH"],
           fm.isExecutableFile(atPath: override) {
            let url = URL(fileURLWithPath: override)
            ensureExecutableBit(at: url)
            cachedBackendURL = url
            return url
        }

        if let bundleURL = resourceBundle.url(
            forResource: backendExecutableName,
            withExtension: nil,
            subdirectory: backendSubdirectory
        ), fm.isExecutableFile(atPath: bundleURL.path) {
            ensureExecutableBit(at: bundleURL)
            cachedBackendURL = bundleURL
            return bundleURL
        }

        if let workspaceURL = resolveWorkspaceBackend() {
            ensureExecutableBit(at: workspaceURL)
            cachedBackendURL = workspaceURL
            return workspaceURL
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return URL(fileURLWithPath: "/usr/bin/false")
        }
        #endif
        fatalError("Backend executable \(backendExecutableName) not found in app bundle or workspace")
    }

    public static func modelURL(named name: String = defaultModelName) -> URL {
        if let cachedModelURL, FileManager.default.fileExists(atPath: cachedModelURL.path) {
            return cachedModelURL
        }

        if let bundleURL = resolveResource(
            named: name,
            extension: modelExtension,
            subdirectory: modelSubdirectory
        ) {
            cachedModelURL = bundleURL
            return bundleURL
        }

        if let workspaceURL = resolveWorkspaceModel(named: name) {
            cachedModelURL = workspaceURL
            return workspaceURL
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return URL(fileURLWithPath: "/tmp/\(name).\(modelExtension)")
        }
        #endif
        fatalError("Model \(name).\(modelExtension) not found in app bundle or workspace")
    }

    public static func refreshCaches() {
        cachedBackendURL = nil
        cachedModelURL = nil
    }

    private static func ensureExecutableBit(at url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes?[.posixPermissions] as? NSNumber {
            let current = permissions.uint16Value
            if current & 0o111 != 0 {
                return
            }
        }

        let desiredPermissions: NSNumber = 0o755
        do {
            try FileManager.default.setAttributes([.posixPermissions: desiredPermissions], ofItemAtPath: url.path)
        } catch {
            vxLog("[resource/ensureExecutableBit] Failed to update execute bit for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func resolveResource(named name: String, extension ext: String?, subdirectory: String) -> URL? {
        if let bundleURL = resourceBundle.url(
            forResource: name,
            withExtension: ext,
            subdirectory: subdirectory
        ) {
            return bundleURL
        }

        return nil
    }

    private static func resolveWorkspaceModel(named name: String) -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let modelsDir = cwd
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(modelSubdirectory, isDirectory: true)
        let filename = "\(name).\(modelExtension)"
        let candidate = modelsDir.appendingPathComponent(filename, isDirectory: false)
        return resolveIfExists(url: candidate)
    }

    private static func resolveWorkspaceBackend() -> URL? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)

        let candidates: [URL] = [
            cwd
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(backendSubdirectory, isDirectory: true)
                .appendingPathComponent(backendExecutableName, isDirectory: false),
            cwd
                .appendingPathComponent("../vx-rs/target/release", isDirectory: true)
                .appendingPathComponent(backendExecutableName, isDirectory: false),
            cwd
                .appendingPathComponent("../vx-rs/target/debug", isDirectory: true)
                .appendingPathComponent(backendExecutableName, isDirectory: false)
        ]

        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            if fm.isExecutableFile(atPath: resolved.path) {
                return resolved
            }
        }

        return nil
    }

    private static func resolveIfExists(url: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url
        }
        let resolved = url.resolvingSymlinksInPath()
        if fm.fileExists(atPath: resolved.path) {
            return resolved
        }
        return nil
    }
}

