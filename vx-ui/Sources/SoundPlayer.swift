import AVFoundation
import CoreAudio
import Foundation

/// Plays short UI sounds, respecting system volume and mute state.
final class SoundPlayer {
    private var player: AVAudioPlayer?

    func play(_ filename: String) {
        guard !isSystemMuted() else { return }
        guard let url = resolve(filename) else {
            vxLog("[sound/play] File not found: \(filename)")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            let ok = p.play()
            player = p
            if !ok { vxLog("[sound/play] play() returned false for \(filename)") }
        } catch {
            vxLog("[sound/play] Failed to play \(filename): \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func resolve(_ filename: String) -> URL? {
        let name = (filename as NSString).deletingPathExtension
        let ext  = (filename as NSString).pathExtension

        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("Resources").appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func isSystemMuted() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard deviceID != kAudioObjectUnknown else { return false }

        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }
}
