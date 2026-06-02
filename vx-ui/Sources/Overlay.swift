import AppKit
import SwiftUI

enum OverlayState: Equatable {
    case idle(String)
    case listening
    case processing
    case inserting
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle(let text):
            return text
        case .listening:
            return "Listening…"
        case .processing:
            return "Transcribing…"
        case .inserting:
            return "Inserting…"
        case .success(let text):
            return text
        case .failure(let text):
            return text
        }
    }

    var showsSpinner: Bool {
        switch self {
        case .listening, .processing, .inserting:
            return true
        default:
            return false
        }
    }

    var systemImageName: String? {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        default:
            return nil
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return .green
        case .failure:
            return .red
        default:
            return .accentColor
        }
    }
}

final class OverlayViewModel: ObservableObject {
    @Published var state: OverlayState = .idle("")
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.state.showsSpinner {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if let symbol = viewModel.state.systemImageName {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(viewModel.state.tint)
            }

            Text(viewModel.state.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 420, minHeight: 56, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .shadow(radius: 6)
    }
}

#if DEBUG
#Preview("Idle") {
    let vm = OverlayViewModel()
    vm.state = .idle("Hold Option-Space to dictate")
    return OverlayView(viewModel: vm)
        .padding()
}

#Preview("Listening") {
    let vm = OverlayViewModel()
    vm.state = .listening
    return OverlayView(viewModel: vm)
        .padding()
}

#Preview("Processing") {
    let vm = OverlayViewModel()
    vm.state = .processing
    return OverlayView(viewModel: vm)
        .padding()
}

#Preview("Success") {
    let vm = OverlayViewModel()
    vm.state = .success("Transcription inserted")
    return OverlayView(viewModel: vm)
        .padding()
}

#Preview("Failure") {
    let vm = OverlayViewModel()
    vm.state = .failure("Microphone not available")
    return OverlayView(viewModel: vm)
        .padding()
}
#endif

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayWindow: NSObject {
    private let viewModel: OverlayViewModel
    private let window: OverlayPanel
    private var idleMessage: String
    private var hasCustomPosition = false
    private let defaults = UserDefaults.standard
    private let frameKey = "vx.overlay.frame"

    init(viewModel: OverlayViewModel = OverlayViewModel(), idleMessage: String = "Hold Option-Space to dictate") {
        self.viewModel = viewModel
        self.idleMessage = idleMessage
        self.viewModel.state = .idle(idleMessage)
        let hostingController = NSHostingController(rootView: OverlayView(viewModel: viewModel))

        window = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 68),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentViewController = hostingController
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 200, height: 56)
        window.maxSize = NSSize(width: 520, height: 180)

        super.init()
        window.delegate = self
        if !restoreFrame() {
            positionIfNeeded()
        }
    }

    func present(_ state: OverlayState) {
        viewModel.state = state
        positionIfNeeded()
        window.orderFrontRegardless()
    }

    func update(_ state: OverlayState) {
        guard window.isVisible else {
            present(state)
            return
        }
        viewModel.state = state
    }

    func updateIdleMessage(_ message: String) {
        idleMessage = message
        if case .idle = viewModel.state {
            viewModel.state = .idle(message)
        }
    }

    func dismiss(after delay: TimeInterval = 0) {
        let resetState = { [weak self] in
            guard let self else { return }
            self.viewModel.state = .idle(self.idleMessage)
        }

        if delay == 0 {
            window.orderOut(nil)
            resetState()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.window.orderOut(nil)
                resetState()
            }
        }
    }

    private func positionIfNeeded() {
        guard !hasCustomPosition, let screen = NSScreen.main else { return }
        let frame = window.frame
        let origin = NSPoint(
            x: screen.frame.midX - frame.width / 2,
            y: screen.frame.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func restoreFrame() -> Bool {
        guard let string = defaults.string(forKey: frameKey) else { return false }
        let rect = NSRectFromString(string)
        window.setFrame(rect, display: false)
        hasCustomPosition = true
        return true
    }

    private func persistFrame() {
        let serialized = NSStringFromRect(window.frame)
        defaults.set(serialized, forKey: frameKey)
    }
}

extension OverlayWindow: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        hasCustomPosition = true
        persistFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        hasCustomPosition = true
        persistFrame()
    }
}
