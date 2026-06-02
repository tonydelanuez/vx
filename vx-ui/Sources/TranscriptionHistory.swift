import AppKit
import Foundation
import SwiftUI

// MARK: - Model

final class TranscriptionHistory: ObservableObject {
    static let shared = TranscriptionHistory()

    struct Entry: Identifiable, Codable {
        var id: UUID
        var text: String
        var timestamp: Date
    }

    @Published private(set) var entries: [Entry] = []

    private static let defaultsKey = "vx.transcription-history"
    private static let maxEntries = 50

    private init() {
        load()
    }

    func append(_ text: String) {
        let entry = Entry(id: UUID(), text: text, timestamp: Date())
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - View

struct TranscriptionHistoryView: View {
    @ObservedObject private var history = TranscriptionHistory.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcription History")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    history.clear()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            if history.entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No transcriptions yet")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.entries) { entry in
                            HistoryEntryRow(entry: entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 480)
    }
}

private struct HistoryEntryRow: View {
    let entry: TranscriptionHistory.Entry
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt
    }()

    private var relativeTimestamp: String {
        let age = Date().timeIntervalSince(entry.timestamp)
        if age < 60 {
            return "just now"
        } else if age < 3600 {
            return "\(Int(age / 60))m ago"
        } else {
            return Self.timeFormatter.string(from: entry.timestamp)
        }
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copied = false
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(copied ? "Copied!" : relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .frame(width: 60, alignment: .leading)
                Text(entry.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(copied ? Color.green.opacity(0.08) : Color.clear)
            .animation(.easeInOut(duration: 0.15), value: copied)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Controller

final class TranscriptionHistoryController {
    private weak var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: TranscriptionHistoryView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "vx History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 380, height: 480))
        window.setFrameAutosaveName("TranscriptionHistoryWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
