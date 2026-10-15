import Foundation
import Combine

public enum ModelInstallState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installing
    case cancelling
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
        if case .downloading(let value) = self { return value }
        return nil
    }
}

/// Model state belongs to the main queue. Downloads and archive installation run
/// off that queue so model management does not block dictation or Preferences.
public final class ModelManager: ObservableObject {
    public static let shared = ModelManager()
    @Published public private(set) var states: [String: ModelInstallState] = [:]
    private var downloads: [String: Download] = [:]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        refreshInstalledStates()
    }

    public static func resolvedModelURL(fileName: String) -> URL? {
        guard let model = SpeechModel.catalog.first(where: { $0.fileName == fileName }) else { return nil }
        return modelLocations(fileName: fileName).first { model.isComplete(at: $0) }
    }

    private static func modelLocations(fileName: String) -> [URL] {
        var locations = [userModelsDirectoryURL().appendingPathComponent(fileName)]
        if let resources = Bundle.main.resourceURL {
            locations.append(resources.appendingPathComponent("Models/\(fileName)"))
        }
        // Support both `swift run` from vx-ui and verification from the workspace root.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        locations.append(cwd.appendingPathComponent("Resources/Models/\(fileName)"))
        locations.append(cwd.appendingPathComponent("app/vx-ui/Resources/Models/\(fileName)"))
        return locations
    }

    public static func userModelsDirectoryURL() -> URL {
        RuntimeProfile.current.userModelsDirectory
    }

    public func refreshInstalledStates() {
        for model in SpeechModel.catalog {
            if downloads[model.id] != nil { continue }
            states[model.id] = Self.resolvedModelURL(fileName: model.fileName) == nil ? .notInstalled : .installed
        }
    }

    public func isBundledOnly(_ model: SpeechModel) -> Bool {
        let userURL = Self.userModelsDirectoryURL().appendingPathComponent(model.fileName)
        return !model.isComplete(at: userURL) && Self.resolvedModelURL(fileName: model.fileName) != nil
    }

    public func download(_ model: SpeechModel) {
        guard downloads[model.id] == nil, states[model.id] != .installed else { return }
        let job = Download()
        downloads[model.id] = job
        states[model.id] = .downloading(progress: 0)
        let task = session.downloadTask(with: model.downloadURL) { [weak self] temporary, response, error in
            // URLSession removes its temporary file when this callback returns.
            // Install synchronously here, on its background callback queue.
            let result: Result<Void, Error> = Result {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw ModelInstaller.InstallError.invalid("The model server could not complete the download. Please retry.")
                }
                guard let temporary else { throw ModelInstaller.InstallError.invalid("No model file received.") }
                DispatchQueue.main.async {
                    guard let self, self.downloads[model.id] === job, !job.isCancelled else { return }
                    self.states[model.id] = .installing
                }
                try ModelInstaller.install(model, from: temporary, into: Self.userModelsDirectoryURL(), isCancelled: { job.isCancelled })
            }
            DispatchQueue.main.async {
                guard let self, self.downloads[model.id] === job else { return }
                job.observation?.invalidate()
                job.observation = nil
                job.task = nil
                self.downloads.removeValue(forKey: model.id)
                switch result {
                case .success:
                    self.states[model.id] = .installed
                    vxLog("[model/download] Installed \(model.id)")
                case .failure(let error):
                    self.states[model.id] = job.isCancelled ? .notInstalled : .failed(error.localizedDescription)
                    vxLog("[model/download] \(model.id): \(error.localizedDescription)")
                }
            }
        }
        job.task = task
        job.observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                guard let self, self.downloads[model.id] === job, !job.isCancelled,
                      case .downloading = self.states[model.id] else { return }
                // Transfer progress stops at installation. Queued KVO updates
                // must not replace the spinner during hashing and extraction.
                self.states[model.id] = fraction >= 1 ? .installing : .downloading(progress: fraction)
            }
        }
        task.resume()
        vxLog("[model/download] Started \(model.id)")
    }

    public func cancelDownload(for model: SpeechModel) {
        guard let job = downloads[model.id] else { return }
        job.cancel()
        states[model.id] = .cancelling
    }

    public func remove(_ model: SpeechModel, activeModelId: String) {
        guard model.id != activeModelId, downloads[model.id] == nil else { return }
        let userURL = Self.userModelsDirectoryURL().appendingPathComponent(model.fileName)
        guard FileManager.default.fileExists(atPath: userURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: userURL)
            refreshInstalledStates()
            vxLog("[model/remove] Removed \(model.id)")
        } catch {
            states[model.id] = .failed(error.localizedDescription)
            vxLog("[model/remove] \(model.id): \(error)")
        }
    }

    private final class Download {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            task?.cancel()
        }
    }
}
