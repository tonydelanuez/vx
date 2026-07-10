import AVFoundation
import CoreAudio
import CoreMedia
import Combine
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: String  // same as uid, used by SwiftUI
    let name: String
    var uid: String { id }
}

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is required to capture audio."
        case .captureUnavailable:
            return "Unable to start microphone capture."
        }
    }
}

/// Converts AVCaptureSession audio sample buffers (device-native format) to 16 kHz mono f32,
/// forwards them, and publishes a normalized level. Runs on the capture queue (off main).
private final class AudioSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let level: CurrentValueSubject<Double, Never>
    private let onSamples: ([Float]) -> Void
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var loggedFormat = false

    init(level: CurrentValueSubject<Double, Never>, onSamples: @escaping ([Float]) -> Void) {
        self.level = level
        self.onSamples = onSamples
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let inFormat = AVAudioFormat(streamDescription: asbd) else { return }
        if !loggedFormat {
            loggedFormat = true
            vxLog("[audio/capture] Device format: \(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch")
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList
        ) == noErr else { return }

        if converter == nil { converter = AVAudioConverter(from: inFormat, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / inFormat.sampleRate + 1)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        converter.convert(to: outBuf, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        guard let data = outBuf.floatChannelData, outBuf.frameLength > 0 else { return }
        let n = Int(outBuf.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data[0], count: n))
        onSamples(samples)

        // Normalized RMS for the HUD level meter.
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = (sumSq / Float(n)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -160
        level.send(Double(max(0, min(1, (db + 60) / 60))))
    }
}

final class AudioCapture {
    private var engine: AVAudioEngine?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioSampleDelegate?
    private var captureErrorObserver: NSObjectProtocol?
    private var currentURL: URL?
    private let levelSubject = CurrentValueSubject<Double, Never>(0)

    /// Emits normalized audio levels (0...1) while recording.
    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// Starts recording audio.
    ///
    /// - Parameters:
    ///   - deviceUID: Core Audio device UID to use; `nil` = system default.
    ///   - session: When non-nil, 16 kHz mono f32 frames are pushed to the transcription
    ///     session via `write(samples:)` instead of being written to a WAV file. The returned
    ///     URL is a sentinel temp path that is never written to disk; streaming callers ignore it.
    ///   - sampleSink: Optional lower-level streaming sink. Used by Go mode to segment
    ///     continuous microphone audio into utterances while keeping capture alive.
    @discardableResult
    func startRecording(
        deviceUID: String? = nil,
        session: TranscriptionSession? = nil,
        sampleSink: (([Float]) -> Void)? = nil
    ) throws -> URL {
        try AudioCapture.ensurePermission()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-dictation-\(UUID().uuidString).wav")
        let streamingSink: (([Float]) -> Void)? = sampleSink ?? session.map { transcriptionSession in
            { samples in transcriptionSession.write(samples: samples) }
        }

        // For an explicitly-selected input device, capture via AVCaptureSession instead of
        // AVAudioEngine. AVAudioEngine's IO unit couples the input to the output device, so
        // forcing a different input (the Yeti) while a Bluetooth device is the output fails
        // with kAudioUnitErr_FormatNotSupported (-10868). AVCaptureSession records from a
        // chosen device independent of the output, sidestepping that entirely. The system-
        // default path (no device chosen) keeps using AVAudioEngine.
        if let streamingSink, let uid = deviceUID, let device = AVCaptureDevice(uniqueID: uid) {
            return try startCaptureSession(device: device, sink: streamingSink, url: url)
        }

        let engine = AVAudioEngine()

        // NOTE: Do NOT call engine.prepare() here. prepare() is not declared `throws`
        // in Swift — it raises an ObjC NSException on failure which Swift can't catch,
        // crashing the process. engine.start() is `throws` and handles failures properly.
        // It implicitly calls prepare() internally.

        // Set specific input device if requested.
        // Only skip explicit device selection when the requested input device IS Bluetooth.
        // Setting kAudioOutputUnitProperty_CurrentDevice on the AUHAL for a Bluetooth device
        // creates a split I/O configuration that CoreAudio cannot resolve the format chain for,
        // causing engine.start() to fail with kAudioUnitErr_FormatNotSupported. For non-Bluetooth
        // inputs (e.g. webcam mic) this property works correctly even when a Bluetooth device is
        // the system output — so we attempt explicit selection regardless of the output device.
        if let uid = deviceUID,
           let deviceID = AudioCapture.coreAudioDeviceID(forUID: uid) {
            let name = AudioCapture.coreAudioDeviceName(for: deviceID) ?? uid
            if AudioCapture.isBluetoothDevice(deviceID) {
                vxLog("[audio/startRecording] Selected input '\(name)' is Bluetooth — using system default to avoid AUHAL split I/O issue")
                AudioCapture.logSystemDefaultDevice()
            } else if AudioCapture.setEngineInputDevice(deviceID, on: engine) {
                vxLog("[audio/startRecording] Using input device: \(name)")
            } else {
                vxLog("[audio/startRecording] Could not set input device '\(name)', falling back to system default")
                AudioCapture.logSystemDefaultDevice()
            }
        } else if let uid = deviceUID {
            vxLog("[audio/startRecording] Input device UID '\(uid)' not found, falling back to system default")
            AudioCapture.logSystemDefaultDevice()
        } else {
            AudioCapture.logSystemDefaultDevice()
        }

        let inputNode = engine.inputNode
        let subject = levelSubject

        if let streamingSink {
            // Streaming mode: convert to f32 16 kHz mono and push frames to the session.
            let f32Format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false)!
            var converter: AVAudioConverter?
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                if converter == nil {
                    converter = AVAudioConverter(from: buffer.format, to: f32Format)
                    if converter == nil {
                        vxLog("[audio/startRecording] Could not create f32 converter from \(buffer.format)")
                    }
                }
                guard let converter else { return }

                let ratio = f32Format.sampleRate / buffer.format.sampleRate
                let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: f32Format, frameCapacity: outputCapacity) else { return }

                var inputConsumed = false
                converter.convert(to: outBuffer, error: nil) { _, status in
                    if inputConsumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    status.pointee = .haveData
                    return buffer
                }

                if let floatData = outBuffer.floatChannelData {
                    let frameCount = Int(outBuffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                    streamingSink(samples)
                }

                let power = AudioCapture.averagePower(from: buffer)
                subject.send(AudioCapture.normalize(power: power))
            }
            vxLog("[audio/startRecording] Streaming mode: pushing f32 16kHz frames to session")
        } else {
            // WAV file mode (existing path).
            let targetSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let audioFile = try AVAudioFile(forWriting: url, settings: targetSettings)
            let processingFormat = audioFile.processingFormat

            // Pass nil for the tap format so AVAudioEngine does not call SetOutputFormat on
            // the input node. Querying outputFormat(forBus:) before the engine starts returns
            // a "best guess" that can differ from the real hardware format when Bluetooth
            // output devices (AirPods, etc.) are present — passing that stale format causes
            // AVAudioIONodeImpl::SetOutputFormat to raise an uncatchable NSException.
            // With nil, the tap receives buffers in the hardware's native format and we build
            // the AVAudioConverter lazily on the first buffer when the real format is known.
            var converter: AVAudioConverter?
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
                if converter == nil {
                    converter = AVAudioConverter(from: buffer.format, to: processingFormat)
                    if converter == nil {
                        vxLog("[audio/startRecording] Could not create audio converter from \(buffer.format) to \(processingFormat)")
                    }
                }
                guard let converter else { return }

                let ratio = processingFormat.sampleRate / buffer.format.sampleRate
                let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: outputCapacity) else { return }

                var conversionError: NSError?
                var inputConsumed = false
                converter.convert(to: outBuffer, error: &conversionError) { _, status in
                    if inputConsumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    status.pointee = .haveData
                    return buffer
                }

                if conversionError == nil {
                    try? audioFile.write(from: outBuffer)
                }

                let power = AudioCapture.averagePower(from: buffer)
                subject.send(AudioCapture.normalize(power: power))
            }
        }

        do {
            try engine.start()
        } catch {
            // Tear the half-built engine down so a failed start never leaks an audio unit
            // bound to the HAL. Leaked units from repeated failures (common when a Bluetooth
            // output device is mid A2DP<->SCO transition and start() fails with -10868)
            // accumulate and eventually wedge CoreAudio, hanging the whole app.
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }

        self.engine = engine
        self.currentURL = url
        levelSubject.send(0)
        vxLog("[audio/startRecording] Started: \(url.lastPathComponent)")
        return url
    }

    /// Streaming capture from an explicitly-chosen device via AVCaptureSession — records from
    /// the device independent of the output device, so it works when a different (e.g.
    /// Bluetooth) device is the system output, unlike the AVAudioEngine input-device override.
    private func startCaptureSession(device: AVCaptureDevice, sink: @escaping ([Float]) -> Void, url: URL) throws -> URL {
        let capture = AVCaptureSession()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            vxLog("[audio/capture] Could not open input '\(device.localizedName)': \(error.localizedDescription)")
            throw AudioCaptureError.captureUnavailable
        }
        guard capture.canAddInput(input) else {
            vxLog("[audio/capture] Cannot add input '\(device.localizedName)'")
            throw AudioCaptureError.captureUnavailable
        }
        capture.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Ask for 32-bit float PCM. The Yeti's native format is 16-bit integer, and converting
        // that to float in the delegate was mis-scaling it to near-silence; requesting float
        // here lets the capture pipeline hand us samples we don't have to reinterpret.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard capture.canAddOutput(output) else {
            vxLog("[audio/capture] Cannot add audio output")
            throw AudioCaptureError.captureUnavailable
        }
        let delegate = AudioSampleDelegate(level: levelSubject) { samples in
            sink(samples)
        }
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.vx.capture.audio"))
        capture.addOutput(output)

        // The session reports failures asynchronously (it doesn't throw) — log them.
        captureErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: capture, queue: nil
        ) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            vxLog("[audio/capture] Runtime error: \(err?.localizedDescription ?? "unknown")")
        }

        capture.startRunning()
        guard capture.isRunning else {
            vxLog("[audio/capture] Session did not start running")
            if let obs = captureErrorObserver { NotificationCenter.default.removeObserver(obs); captureErrorObserver = nil }
            throw AudioCaptureError.captureUnavailable
        }

        self.captureSession = capture
        self.captureDelegate = delegate
        self.currentURL = url
        levelSubject.send(0)
        vxLog("[audio/capture] Capturing from '\(device.localizedName)' via AVCaptureSession")
        return url
    }

    func stopRecording() -> URL? {
        if let capture = captureSession {
            capture.stopRunning()
            captureSession = nil
            captureDelegate = nil
            if let obs = captureErrorObserver { NotificationCenter.default.removeObserver(obs); captureErrorObserver = nil }
            let url = currentURL
            currentURL = nil
            levelSubject.send(0)
            if let url { vxLog("[audio/stopRecording] Stopped capture session: \(url.lastPathComponent)") }
            return url
        }
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        let url = currentURL
        currentURL = nil
        levelSubject.send(0)
        if let url {
            vxLog("[audio/stopRecording] Stopped: \(url.lastPathComponent)")
        } else {
            vxLog("[audio/stopRecording] Stopped with no active file")
        }
        return url
    }

    // MARK: - Device enumeration

    static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)

        return deviceIDs.compactMap { id in
            guard hasInputChannels(deviceID: id),
                  let uid = coreAudioDeviceUID(for: id),
                  let name = coreAudioDeviceName(for: id) else { return nil }
            return AudioInputDevice(id: uid, name: name)
        }
    }

    // MARK: - Private helpers

    // Synchronous check — never blocks the calling thread.
    // AppCoordinator pre-requests permission at launch so this is typically .authorized.
    private static func ensurePermission() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        vxLog("[audio/permission] TCC status: \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
        switch status {
        case .authorized:
            return
        case .notDetermined:
            // Kick off the async request so the next attempt works.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                vxLog("[audio/permission] Result: \(granted)")
            }
            throw AudioCaptureError.permissionDenied
        case .denied, .restricted:
            vxLog("[audio/permission] Denied/restricted")
            throw AudioCaptureError.permissionDenied
        @unknown default:
            return
        }
    }

    static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transportType) == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isBluetoothDefaultOutput() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return false }

        addr.mSelector = kAudioDevicePropertyTransportType
        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transportType) == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    @discardableResult
    private static func setEngineInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else {
            vxLog("[audio/deviceSetup] inputNode.audioUnit is nil; device selection unavailable")
            return false
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    private static func logSystemDefaultDevice() {
        if let id = systemDefaultInputDeviceID(), let name = coreAudioDeviceName(for: id) {
            vxLog("[audio/deviceSetup] Using system default input device: \(name)")
        } else {
            vxLog("[audio/deviceSetup] Using system default input device")
        }
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func coreAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // Pass the CFString as qualifier via a stable pointer (avoids ARC warning).
        let cfUID = uid as CFString
        let status = withUnsafePointer(to: cfUID) { qualifierPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifierPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func coreAudioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Receive as Unmanaged to avoid "UnsafeRawPointer to CFString" warning.
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef) == noErr,
              let ref = nameRef else { return nil }
        return ref.takeRetainedValue() as String
    }

    private static func coreAudioDeviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uidRef) == noErr,
              let ref = uidRef else { return nil }
        return ref.takeRetainedValue() as String
    }

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else { return false }
        return buffer.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
    }

    private static func averagePower(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -160 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, channelCount > 0 else { return -160 }
        var sumOfSquares: Float = 0
        for ch in 0..<channelCount {
            let data = channelData[ch]
            for i in 0..<frameCount {
                sumOfSquares += data[i] * data[i]
            }
        }
        let rms = sqrt(sumOfSquares / Float(channelCount * frameCount))
        return rms > 0 ? 20 * log10(rms) : -160
    }

    private static func normalize(power: Float) -> Double {
        let minDb: Double = -60
        let maxDb: Double = -12
        let db = Double(power)
        if db <= minDb { return 0 }
        if db >= maxDb { return 1 }
        let normalized = min(max((db - minDb) / (maxDb - minDb), 0), 1)
        return pow(normalized, 0.7)
    }
}
