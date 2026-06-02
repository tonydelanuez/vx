import Foundation

/// A locally-runnable Whisper model supported by the vx-rs backend.
public struct WhisperModel: Identifiable, Equatable {
    /// Short unique identifier, e.g. "tiny.en".
    public let id: String
    /// Human-readable name shown in the UI, e.g. "Tiny".
    public let displayName: String
    /// Short quality/speed description shown in the UI.
    public let detail: String
    /// Actual filename on disk, e.g. "ggml-tiny.en.bin".
    public let fileName: String
    /// Approximate download size in megabytes.
    public let approximateSizeMB: Int
    /// Canonical download URL (Hugging Face ggerganov/whisper.cpp).
    public let downloadURL: URL

    /// Bundle resource name (filename without the final .bin extension).
    var resourceName: String {
        (fileName as NSString).deletingPathExtension
    }

    var sizeLabel: String {
        approximateSizeMB >= 1000
            ? String(format: "%.1f GB", Double(approximateSizeMB) / 1000.0)
            : "\(approximateSizeMB) MB"
    }
}

extension WhisperModel {
    // MARK: - Catalog
    // To add a new model, append an entry here. No other changes are required
    // as long as the vx-rs backend supports the ggml format for that model.
    public static let catalog: [WhisperModel] = [
        WhisperModel(
            id: "tiny.en",
            displayName: "Tiny",
            detail: "Fastest, least accurate",
            fileName: "ggml-tiny.en.bin",
            approximateSizeMB: 78,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!
        ),
        WhisperModel(
            id: "base.en",
            displayName: "Base",
            detail: "Balanced speed and accuracy",
            fileName: "ggml-base.en.bin",
            approximateSizeMB: 142,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
        ),
        WhisperModel(
            id: "small.en",
            displayName: "Small",
            detail: "Slower, noticeably better accuracy",
            fileName: "ggml-small.en.bin",
            approximateSizeMB: 466,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!
        ),
    ]

    public static func find(id: String) -> WhisperModel? {
        catalog.first { $0.id == id }
    }

    public static var defaultModel: WhisperModel { catalog[0] }
}
