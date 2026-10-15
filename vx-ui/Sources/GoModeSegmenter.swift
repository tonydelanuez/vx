import Foundation

/// Segments continuous 16 kHz mono f32 microphone audio into utterances for Go mode.
///
/// The audio callback only enqueues work; all thresholding and subprocess writes happen on
/// a private serial queue so microphone capture never has to wait for speech process setup.
final class GoModeSegmenter {
    private enum State {
        case idle
        case speaking
    }

    private let transcriber: Transcriber
    private let modelURL: URL
    private let onTranscript: (String) -> Void
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "voice.vx.go-mode.segmenter", qos: .userInitiated)

    private let startThreshold: Float = 0.018
    private let stopThreshold: Float = 0.010
    private let silenceSamplesToEnd = Int(0.85 * 16_000)
    private let minUtteranceSamples = Int(0.35 * 16_000)
    private let maxUtteranceSamples = 28 * 16_000
    private let prerollSamples = Int(0.25 * 16_000)

    private var state: State = .idle
    private var preRoll: [Float] = []
    private var activeSession: TranscriptionSession?
    private var activeSampleCount = 0
    private var silenceSampleCount = 0
    private var isStopped = false
    private var lastDelivery: Task<Void, Never>?

    init(
        transcriber: Transcriber,
        modelURL: URL,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.transcriber = transcriber
        self.modelURL = modelURL
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }

    func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            self?.handle(samples: samples)
        }
    }

    func stop(finishActive: Bool) {
        queue.async { [self] in
            self.isStopped = true
            if finishActive {
                self.finishActiveSegment()
            } else {
                self.activeSession?.cancel()
                self.resetSegment()
            }
            self.preRoll.removeAll(keepingCapacity: false)
        }
    }

    private func handle(samples: [Float]) {
        guard !isStopped else { return }
        let rms = Self.rms(samples)

        switch state {
        case .idle:
            guard rms >= startThreshold else {
                appendPreRoll(samples)
                return
            }
            do {
                let session = try transcriber.begin(model: modelURL)
                activeSession = session
                state = .speaking
                activeSampleCount = 0
                silenceSampleCount = 0
                if !preRoll.isEmpty {
                    session.write(samples: preRoll)
                    activeSampleCount += preRoll.count
                }
                session.write(samples: samples)
                activeSampleCount += samples.count
                preRoll.removeAll(keepingCapacity: true)
                vxLog("[go-mode/segmenter] Speech started")
            } catch {
                isStopped = true
                DispatchQueue.main.async { self.onFailure(error) }
            }

        case .speaking:
            guard let session = activeSession else {
                resetSegment()
                return
            }
            session.write(samples: samples)
            activeSampleCount += samples.count

            if rms <= stopThreshold {
                silenceSampleCount += samples.count
            } else {
                silenceSampleCount = 0
            }

            if activeSampleCount >= maxUtteranceSamples {
                vxLog("[go-mode/segmenter] Segment hit max duration; finishing")
                finishActiveSegment()
            } else if silenceSampleCount >= silenceSamplesToEnd {
                if activeSampleCount >= minUtteranceSamples {
                    vxLog("[go-mode/segmenter] Silence boundary reached; finishing")
                    finishActiveSegment()
                } else {
                    vxLog("[go-mode/segmenter] Dropping too-short segment")
                    activeSession?.cancel()
                    resetSegment()
                }
            }
        }
    }

    private func appendPreRoll(_ samples: [Float]) {
        preRoll.append(contentsOf: samples)
        if preRoll.count > prerollSamples {
            preRoll.removeFirst(preRoll.count - prerollSamples)
        }
    }

    private func finishActiveSegment() {
        guard let session = activeSession else {
            resetSegment()
            return
        }
        resetSegment()

        let previous = lastDelivery
        lastDelivery = Task.detached { [onTranscript, onFailure] in
            let result: Result<String, Error>
            do { result = .success(try await session.finish()) }
            catch { result = .failure(error) }
            // Inference may finish out of order, but phrases must retain recording order.
            await previous?.value
            switch result {
            case .success(let text):
                DispatchQueue.main.async { onTranscript(text) }
            case .failure(is CancellationError):
                vxLog("[go-mode/segmenter] Segment cancelled")
            case .failure(let error):
                DispatchQueue.main.async { onFailure(error) }
            }
        }
    }

    private func resetSegment() {
        activeSession = nil
        activeSampleCount = 0
        silenceSampleCount = 0
        state = .idle
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
}
