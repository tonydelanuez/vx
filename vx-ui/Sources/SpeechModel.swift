import Foundation

public enum SpeechEngine: String, Equatable {
    case whisper
    case parakeet
}

/// A local speech model supported by the vx-rs backend.
public struct SpeechModel: Identifiable, Equatable {
    /// Short unique identifier, e.g. "tiny.en".
    public let id: String
    /// Human-readable name shown in the UI, e.g. "Tiny".
    public let displayName: String
    /// Short quality/speed description shown in the UI.
    public let detail: String
    /// Model file or directory name on disk.
    public let fileName: String
    /// Approximate download size in megabytes.
    public let approximateSizeMB: Int
    /// Canonical model download URL.
    public let downloadURL: URL

    public var engine: SpeechEngine = .whisper
    /// Parakeet archives use a pinned checksum before extraction.
    public var archiveSHA256: String? = nil

    public static let parakeetFiles = [
        "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"
    ]

    public var isParakeet: Bool { engine == .parakeet }

    /// A partial download must never appear as an installed model.
    public func isComplete(at url: URL) -> Bool {
        let paths = isParakeet
            ? Self.parakeetFiles.map { url.appendingPathComponent($0) }
            : [url]
        return paths.allSatisfy { path in
            guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

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

extension SpeechModel {
    // MARK: - Catalog
    // Entries must match a model format supported by vx-rs.
    public static let catalog: [SpeechModel] = [
        SpeechModel(
            id: "tiny.en",
            displayName: "Tiny",
            detail: "Fastest, least accurate",
            fileName: "ggml-tiny.en.bin",
            approximateSizeMB: 78,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!
        ),
        SpeechModel(
            id: "base.en",
            displayName: "Base",
            detail: "Balanced speed and accuracy",
            fileName: "ggml-base.en.bin",
            approximateSizeMB: 142,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
        ),
        SpeechModel(
            id: "small.en",
            displayName: "Small",
            detail: "Slower, noticeably better accuracy",
            fileName: "ggml-small.en.bin",
            approximateSizeMB: 466,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!
        ),
        // NVIDIA reports English average WER of 6.05% for v2 and 6.34% for v3.
        // These are upstream results, not measurements of our INT8 conversions.
        // Sources: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2#performance
        //          https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3#performance
        SpeechModel(
            id: "parakeet-tdt-0.6b-v2-int8",
            displayName: "Parakeet v2 (English)",
            detail: "Lower reported English error rate than v3. No GPU required.",
            fileName: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
            approximateSizeMB: 482,
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2")!,
            engine: .parakeet,
            archiveSHA256: "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad"
        ),
        SpeechModel(
            id: "parakeet-tdt-0.6b-v3-int8",
            displayName: "Parakeet v3",
            detail: "Larger model, high accuracy. No GPU required.",
            fileName: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            approximateSizeMB: 487,
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2")!,
            engine: .parakeet,
            archiveSHA256: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
        ),
    ]

    public static func find(id: String) -> SpeechModel? {
        catalog.first { $0.id == id }
    }

    public static var defaultModel: SpeechModel { catalog[0] }
}
