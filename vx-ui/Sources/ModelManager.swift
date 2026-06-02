import Foundation
import Combine

// MARK: - Install state

public enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(String)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    public var downloadProgress: Double? {
        if case .downloading(let p) = self { return p }
        return nil
    }
}

// MARK: - Manager

/// Tracks install state for all catalog models and manages downloads.
/// All @Published mutations happen on the main queue.
public final class ModelManager: ObservableObject {
    public static let shared = ModelManager()

    @Published public private(set) var states: [String: ModelInstallState] = [:]

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    private init() {
        refreshInstalledStates()
    }

    // MARK: - Resolution

    /// Resolves the URL for a model file, checking (in order):
    /// 1. User models directory (~/Library/Application Support/vx/Models/)
    /// 2. App bundle (Contents/Resources/Models/)
    /// 3. Workspace-relative path (for `swift run` development)
    public static func resolvedModelURL(fileName: String) -> URL? {
        let fm = FileManager.default

        let userURL = userModelsDirectoryURL().appendingPathComponent(fileName)
        if fm.fileExists(atPath: userURL.path) {
            return userURL
        }

        let resourceName = (fileName as NSString).deletingPathExtension
        if let bundleURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: "bin",
            subdirectory: "Models"
        ) {
            return bundleURL
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let workspaceURL = cwd
            .appendingPathComponent("Resources/Models")
            .appendingPathComponent(fileName)
        if fm.fileExists(atPath: workspaceURL.path) {
            return workspaceURL
        }

        return nil
    }

    /// The directory where downloaded models are stored.
    public static func userModelsDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vx/Models")
    }

    // MARK: - State

    public func refreshInstalledStates() {
        for model in WhisperModel.catalog {
            if case .downloading = states[model.id] { continue }
            let installed = Self.resolvedModelURL(fileName: model.fileName) != nil
            DispatchQueue.main.async { self.states[model.id] = installed ? .installed : .notInstalled }
        }
    }

    /// True when the only available copy of this model is in the read-only app bundle.
    public func isBundledOnly(_ model: WhisperModel) -> Bool {
        let userURL = Self.userModelsDirectoryURL().appendingPathComponent(model.fileName)
        guard !FileManager.default.fileExists(atPath: userURL.path) else { return false }
        return Self.resolvedModelURL(fileName: model.fileName) != nil
    }

    // MARK: - Download

    public func download(_ model: WhisperModel) {
        guard downloadTasks[model.id] == nil else { return }
        guard states[model.id] != .installed else { return }

        let destDir = Self.userModelsDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async {
                self.states[model.id] = .failed("Cannot create models directory: \(error.localizedDescription)")
            }
            return
        }

        DispatchQueue.main.async { self.states[model.id] = .downloading(progress: 0) }

        let task = URLSession.shared.downloadTask(with: model.downloadURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            let obs = self.progressObservations[model.id]
            DispatchQueue.main.async {
                obs?.invalidate()
                self.progressObservations.removeValue(forKey: model.id)
                self.downloadTasks.removeValue(forKey: model.id)

                if let error {
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorCancelled {
                        self.states[model.id] = .notInstalled
                    } else {
                        vxLog("[model/download] Failed for \(model.id): \(error)")
                        self.states[model.id] = .failed(error.localizedDescription)
                    }
                    return
                }

                guard let tempURL else {
                    self.states[model.id] = .failed("No file received")
                    return
                }

                let destURL = destDir.appendingPathComponent(model.fileName)
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                    vxLog("[model/download] Installed \(model.id) to \(destURL.path)")
                    self.states[model.id] = .installed
                } catch {
                    vxLog("[model/download] Move failed for \(model.id): \(error)")
                    self.states[model.id] = .failed(error.localizedDescription)
                }
            }
        }

        let obs = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                if case .downloading = self.states[model.id] {
                    self.states[model.id] = .downloading(progress: fraction)
                }
            }
        }

        progressObservations[model.id] = obs
        downloadTasks[model.id] = task
        task.resume()
        vxLog("[model/download] Started for \(model.id) from \(model.downloadURL)")
    }

    public func cancelDownload(for model: WhisperModel) {
        downloadTasks[model.id]?.cancel()
        progressObservations[model.id]?.invalidate()
        downloadTasks.removeValue(forKey: model.id)
        progressObservations.removeValue(forKey: model.id)
        DispatchQueue.main.async { self.states[model.id] = .notInstalled }
    }

    // MARK: - Removal

    public func remove(_ model: WhisperModel, activeModelId: String) {
        guard model.id != activeModelId else { return }
        let userURL = Self.userModelsDirectoryURL().appendingPathComponent(model.fileName)
        guard FileManager.default.fileExists(atPath: userURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: userURL)
            DispatchQueue.main.async { self.states[model.id] = .notInstalled }
            vxLog("[model/remove] Removed \(model.id)")
        } catch {
            vxLog("[model/remove] Failed to remove \(model.id): \(error)")
        }
    }
}
