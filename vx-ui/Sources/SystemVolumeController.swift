import AudioToolbox
import CoreAudio
import Foundation

/// Smoothly ducks and restores system output volume around recording sessions.
/// Must be called from the main thread (as it is when owned by AppCoordinator).
final class SystemVolumeController {
    private var originalVolume: Float = 1.0
    private var isDucked = false
    private var fadeTimer: Timer?

    /// Duck output volume to `targetVolume` (0.0–1.0) with a smooth fade.
    /// No-ops if already ducked or if current volume is already at or below the target.
    func duck(to targetVolume: Float) {
        guard !isDucked else { return }
        let t0 = Date()
        let current = getSystemVolume()
        vxLog("[volume/duck] getSystemVolume: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
        guard current > targetVolume + 0.01 else { return }
        originalVolume = current
        isDucked = true
        vxLog("[volume/duck] \(String(format: "%.0f", current * 100))% → \(String(format: "%.0f", targetVolume * 100))%")
        fade(from: current, to: targetVolume)
    }

    /// Restore output volume to the level captured at the last `duck(to:)` call.
    func restore() {
        guard isDucked else { return }
        isDucked = false
        let t0 = Date()
        let current = getSystemVolume()
        vxLog("[volume/restore] getSystemVolume: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
        vxLog("[volume/restore] \(String(format: "%.0f", current * 100))% → \(String(format: "%.0f", originalVolume * 100))%")
        fade(from: current, to: originalVolume)
    }

    // MARK: - Private

    private func fade(from start: Float, to target: Float, duration: TimeInterval = 0.2) {
        fadeTimer?.invalidate()
        let startTime = Date()
        let label = target < start ? "duck" : "restore"

        // Use .common mode so the timer fires even when the run loop is handling
        // events (e.g., during audio engine teardown on the main thread).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Float(Date().timeIntervalSince(startTime))
            let t = min(elapsed / Float(duration), 1.0)
            // Smoothstep easing: 3t² - 2t³
            let eased = t * t * (3 - 2 * t)
            self.setSystemVolume(start + (target - start) * eased)
            if t >= 1.0 {
                timer.invalidate()
                self.setSystemVolume(target)
                vxLog("[volume/\(label)] fade complete: \(String(format: "%.1f", Double(Date().timeIntervalSince(startTime)) * 1000))ms")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.fadeTimer = timer
    }

    private func defaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func getSystemVolume() -> Float {
        let deviceID = defaultOutputDevice()
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        return volume
    }

    private func setSystemVolume(_ volume: Float) {
        let deviceID = defaultOutputDevice()
        var vol = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
    }
}
