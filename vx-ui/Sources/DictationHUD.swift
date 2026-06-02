import SwiftUI
import AppKit

// MARK: - HUD animation and styling constants
// Tuning: snappier motion → lower response (e.g. 0.15); softer → higher response (e.g. 0.28).
// More/less glow → glowOpacity, glowRadius; longer/shorter success → successDuration.
private enum HUDConfig {
    static let scaleIn: CGFloat = 0.96
    static let scaleOut: CGFloat = 0.97
    static let appearanceSpring = Animation.spring(response: 0.2, dampingFraction: 0.82)
    static let appearanceOpacityIn: Double = 1.0
    static let dismissDuration: TimeInterval = 0.22
    static let dismissCurve: Animation = .easeOut(duration: dismissDuration)
    static let dismissDelayBeforeOrderOut: TimeInterval = 0.28
    static let reduceMotionAppearanceDuration: TimeInterval = 0.2
    static let reduceMotionDismissDuration: TimeInterval = 0.2
    static let glowOpacity: Double = 0.12
    static let glowRadius: CGFloat = 12
    static let glowColor = Color.white
    static let successDuration: TimeInterval = 0.55
    static let styleTransitionDuration: TimeInterval = 0.2
    static let processingPulseAmplitude: CGFloat = 0.02
    static let processingPulseCycle: TimeInterval = 1.4
    static let meterBarCount = 10
    static let meterSpring = Animation.interpolatingSpring(stiffness: 220, damping: 22)
}

/// Backing model shared between the window controller and SwiftUI view.
final class DictationHUDModel: ObservableObject {
    enum State {
        case hidden
        case hint
        case listening
    }

    enum VisualStyle: Equatable {
        case idle
        case recording
        case processing
        case success
        case finishing
        case cancelled
        case warning
        case error
    }

    @Published var state: State = .hidden
    @Published var hintText: String = "Press fn to toggle dictation"
    @Published var level: Double = 0
    @Published var visualStyle: VisualStyle = .idle
    @Published var controlsEnabled = true

    var onCancel: () -> Void = {}
    var onStop: () -> Void = {}
    /// Called with the capsule’s frame in screen coordinates when in listening state; used so the window can pass through hits outside this rect.
    var onCapsuleFrameInScreen: ((CGRect) -> Void)?
}

private struct EquatableRect: Equatable {
    var rect: CGRect
    static func == (l: EquatableRect, r: EquatableRect) -> Bool {
        l.rect.origin.x == r.rect.origin.x && l.rect.origin.y == r.rect.origin.y &&
        l.rect.size.width == r.rect.size.width && l.rect.size.height == r.rect.size.height
    }
}

private struct CapsuleFrameKey: PreferenceKey {
    static var defaultValue: EquatableRect { EquatableRect(rect: .zero) }
    static func reduce(value: inout EquatableRect, nextValue: () -> EquatableRect) {
        value = nextValue()
    }
}

struct DictationHUD: View {
    @ObservedObject var model: DictationHUDModel
    @Namespace private var hudNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var exitTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .opacity.combined(with: .scale(scale: HUDConfig.scaleOut))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.state != .hidden {
                content
                    .transition(AnyTransition.asymmetric(insertion: .opacity, removal: exitTransition))
                    .overlay(Group {
                        if model.state != .listening {
                            Color.clear.preference(key: CapsuleFrameKey.self, value: EquatableRect(rect: .zero))
                        }
                    })
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: HUDConfig.reduceMotionDismissDuration) : HUDConfig.dismissCurve,
            value: model.state
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 28)
        .padding(.horizontal, 24)
        .padding(.top, (model.state == .listening && model.visualStyle == .recording) ? HUDConfig.glowRadius : 0)
        .onPreferenceChange(CapsuleFrameKey.self) { value in
            model.onCapsuleFrameInScreen?(value.rect)
        }
        .allowsHitTesting(model.state == .listening)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hint:
            hintContent
        case .listening:
            listeningContent
        case .hidden:
            EmptyView()
        }
    }

    private var hintContent: some View {
        Text(model.hintText)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .matchedGeometryEffect(id: "hud", in: hudNamespace)
    }

    @State private var hasAppeared = false

    private var listeningContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button(action: model.onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(model.visualStyle == .success ? 0 : (model.controlsEnabled ? 1 : 0.35))
                .allowsHitTesting(model.visualStyle != .success && model.controlsEnabled)

                Group {
                    if model.visualStyle == .processing {
                        ProcessingDots(reduceMotion: reduceMotion)
                    } else if model.visualStyle == .recording {
                        LevelMeter(level: model.level)
                    } else if model.visualStyle == .success {
                        SuccessIndicator()
                    } else {
                        EmptyView()
                    }
                }
                .frame(width: 160, height: 14)

                Button(action: model.onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(model.visualStyle == .success ? 0 : (model.controlsEnabled ? 1 : 0.35))
                .allowsHitTesting(model.visualStyle != .success && model.controlsEnabled)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(
                Capsule()
                    .fill(model.visualStyle.overlayColor)
                    .opacity(model.visualStyle.overlayOpacity)
            )
            .overlay(
                Capsule()
                    .stroke(model.visualStyle.borderColor, lineWidth: model.visualStyle.borderWidth)
                    .opacity(model.visualStyle.borderWidth > 0 ? 1 : 0)
            )
            .clipShape(Capsule())
            .shadow(
                color: model.visualStyle == .recording ? HUDConfig.glowColor.opacity(HUDConfig.glowOpacity) : .clear,
                radius: model.visualStyle == .recording ? HUDConfig.glowRadius : 0
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CapsuleFrameKey.self,
                        value: EquatableRect(rect: geo.frame(in: .global))
                    )
                }
            )
            .padding(model.visualStyle == .recording ? HUDConfig.glowRadius : 0)
            .matchedGeometryEffect(id: "hud", in: hudNamespace)

            if model.visualStyle == .recording || model.visualStyle == .processing {
                Text(model.visualStyle == .recording ? "Recording" : "Transcribing...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .transition(.opacity)
            } else if model.visualStyle == .success {
                Text("Inserted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
        }
        .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : HUDConfig.scaleIn))
        .opacity(hasAppeared ? 1 : 0)
        .animation(
            reduceMotion ? .easeOut(duration: HUDConfig.reduceMotionAppearanceDuration) : HUDConfig.appearanceSpring,
            value: hasAppeared
        )
        .animation(.easeInOut(duration: HUDConfig.styleTransitionDuration), value: model.visualStyle)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: HUDConfig.reduceMotionAppearanceDuration) : HUDConfig.appearanceSpring) {
                hasAppeared = true
            }
        }
        .onChange(of: model.state) { newState in
            if newState != .listening {
                hasAppeared = false
            }
        }
    }
}

/// Segmented level meter: fills segments by threshold for a responsive, minimal look.
private struct LevelMeter: View {
    var level: Double

    private let barCount = HUDConfig.meterBarCount

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(level, 0), 1)
            let segmentWidth = (proxy.size.width - CGFloat(barCount - 1) * 2) / CGFloat(barCount)
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let threshold = Double(index + 1) / Double(barCount)
                    let filled = clamped >= threshold - 0.05
                    let t = Double(index) / Double(barCount)
                    let segmentColor = Color(hue: 0.33 * (1 - t), saturation: 0.7, brightness: 0.95)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(filled ? segmentColor : Color.white.opacity(0.2))
                        .frame(width: max(2, segmentWidth), height: proxy.size.height)
                        .animation(HUDConfig.meterSpring, value: clamped)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct SuccessIndicator: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(maxWidth: .infinity)
    }
}

/// Processing state: blue wave dots; optional subtle pulse when reduceMotion is false.
private struct ProcessingDots: View {
    var reduceMotion: Bool

    private let dotCount = 9

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle: TimeInterval = 1.35
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let progress = elapsed.truncatingRemainder(dividingBy: cycle) / cycle
            let wave = progress * .pi * 2
            let pulseScale = reduceMotion ? 1.0 : (1.0 + HUDConfig.processingPulseAmplitude * sin(elapsed * .pi * 2 / HUDConfig.processingPulseCycle))

            HStack(spacing: 6) {
                ForEach(0..<dotCount, id: \.self) { index in
                    let phase = wave + CGFloat(index) * 0.6
                    let offset = reduceMotion ? 0 : sin(phase) * 4
                    Circle()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 6, height: 6)
                        .offset(y: offset)
                        .opacity(reduceMotion ? 0.7 : (0.5 + 0.35 * Double((sin(phase) + 1) / 2)))
                }
            }
            .frame(maxWidth: .infinity)
            .scaleEffect(pulseScale)
        }
        .allowsHitTesting(false)
        .opacity(0.9)
    }
}

private struct CompletionFlash: View {
    @State private var animate = false

    var body: some View {
        Capsule()
            .stroke(Color.white.opacity(0.85), lineWidth: 2)
            .scaleEffect(animate ? 1.2 : 0.9)
            .opacity(animate ? 0 : 0.75)
            .animation(.easeOut(duration: 0.35), value: animate)
            .onAppear { animate = true }
    }
}

private extension DictationHUDModel.VisualStyle {
    var overlayColor: Color {
        switch self {
        case .idle: return Color.white
        case .recording: return Color.white
        case .processing: return Color.blue
        case .success: return Color.white
        case .finishing: return Color.white
        case .cancelled: return Color.red
        case .warning: return Color.orange
        case .error: return Color.red
        }
    }

    var overlayOpacity: Double {
        switch self {
        case .idle: return 0.05
        case .recording: return 0.1
        case .processing: return 0.18
        case .success: return 0.12
        case .finishing: return 0.18
        case .cancelled: return 0.25
        case .warning: return 0.23
        case .error: return 0.32
        }
    }

    var borderColor: Color {
        switch self {
        case .idle: return .clear
        case .recording: return Color.white.opacity(0.22)
        case .processing: return Color.blue.opacity(0.45)
        case .success: return Color.white.opacity(0.5)
        case .finishing: return Color.white.opacity(0.65)
        case .cancelled: return Color.red.opacity(0.45)
        case .warning: return Color.orange.opacity(0.45)
        case .error: return Color.red.opacity(0.6)
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .idle: return 0
        case .recording: return 1
        case .processing: return 1.6
        case .success: return 1.2
        case .finishing: return 1.8
        case .cancelled: return 1.4
        case .warning: return 1.3
        case .error: return 1.6
        }
    }
}

#if DEBUG
#Preview("Hint") {
    let model = DictationHUDModel()
    model.state = .hint
    model.hintText = "Press fn to toggle dictation"
    return DictationHUD(model: model)
        .frame(width: 360, height: 180)
        .background(.black.opacity(0.5))
}

#Preview("Recording") {
    let model = DictationHUDModel()
    model.state = .listening
    model.visualStyle = .recording
    model.level = 0.5
    model.controlsEnabled = true
    return DictationHUD(model: model)
        .frame(width: 360, height: 180)
        .background(.black.opacity(0.5))
}

#Preview("Processing") {
    let model = DictationHUDModel()
    model.state = .listening
    model.visualStyle = .processing
    model.controlsEnabled = false
    return DictationHUD(model: model)
        .frame(width: 360, height: 180)
        .background(.black.opacity(0.5))
}

#Preview("Success") {
    let model = DictationHUDModel()
    model.state = .listening
    model.visualStyle = .success
    model.controlsEnabled = false
    return DictationHUD(model: model)
        .frame(width: 360, height: 180)
        .background(.black.opacity(0.5))
}
#endif

/// Content view that only accepts hit tests inside the capsule rect (in screen coords); passes through to windows below otherwise.
private final class PassThroughContentView: NSView {
    /// Capsule rect in this view's bounds (window content) coordinates.
    var interactiveFrameInWindow: CGRect = .zero

    var hostingView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let hostingView else { return }
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // When we have no valid capsule rect, pass through so we don’t block the whole window.
        if interactiveFrameInWindow == .zero {
            return super.hitTest(point)
        }
        guard interactiveFrameInWindow.contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Window controller responsible for presenting the HUD above all content.
final class DictationHUDController {
    var isDebugMode: Bool = false {
        didSet { window.backgroundColor = isDebugMode ? NSColor.red.withAlphaComponent(0.3) : .clear }
    }

    private let model = DictationHUDModel()
    private let hosting: NSHostingController<DictationHUD>
    private let window: DraggablePanel
    private let passThroughView = PassThroughContentView()
    private var hintWorkItem: DispatchWorkItem?
    private var pendingHint = false
    private var statusWorkItem: DispatchWorkItem?
    private var activeHintIsCustom = false
    private var smoothedLevel: Double = 0

    init() {
        hosting = NSHostingController(rootView: DictationHUD(model: model))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        window = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        passThroughView.hostingView = hosting.view
        window.contentView = passThroughView
        model.onCapsuleFrameInScreen = { [weak self] frameIn in
            DispatchQueue.main.async {
                guard let self else { return }
                guard frameIn != .zero else {
                    self.passThroughView.interactiveFrameInWindow = .zero
                    return
                }
                let screen = self.window.screen ?? NSScreen.main
                let screenHeight = screen?.frame.height ?? 0
                let appKitRect = CGRect(
                    x: frameIn.minX,
                    y: screenHeight - frameIn.maxY,
                    width: frameIn.width,
                    height: frameIn.height
                )
                let originInWindow = self.window.convertPoint(fromScreen: NSPoint(x: appKitRect.minX, y: appKitRect.minY))
                self.passThroughView.interactiveFrameInWindow = NSRect(origin: originInWindow, size: appKitRect.size)
            }
        }
        window.setFrameAutosaveName("DictationHUDWindow")
        positionWindow()
        hideWindow()
    }

    private var defaultHintText = "Press fn to toggle dictation"

    func updateHint(_ text: String) {
        defaultHintText = text
        if model.state != .listening {
            model.hintText = text
        }
    }

    func showHint(_ text: String? = nil, after delay: TimeInterval = 0.4, duration: TimeInterval = 2.5) {
        guard model.state != .listening else {
            pendingHint = true
            return
        }
        model.hintText = text ?? defaultHintText
        activeHintIsCustom = text != nil
        scheduleHint(after: delay, duration: duration)
    }

    func showListening(onCancel: @escaping () -> Void, onStop: @escaping () -> Void) {
        cancelHint()
        statusWorkItem?.cancel()
        statusWorkItem = nil
        resetHintToDefaultIfNeeded()
        pendingHint = false
        smoothedLevel = 0
        withAnimation {
            model.onCancel = {
                onCancel()
            }
            model.onStop = {
                onStop()
            }
            model.level = 0
            model.visualStyle = .recording
            model.controlsEnabled = true
            model.state = .listening
        }
        updateWindow(for: .listening)
    }

    func hide() {
        cancelHint()
        statusWorkItem?.cancel()
        statusWorkItem = nil
        smoothedLevel = 0
        if isDebugMode {
            withAnimation {
                model.visualStyle = .idle
                model.controlsEnabled = true
                model.level = 0
                model.state = .hint
            }
            resetHintToDefaultIfNeeded()
            updateWindow(for: .hint)
            return
        }
        withAnimation {
            model.state = .hidden
            model.visualStyle = .idle
            model.controlsEnabled = true
            model.level = 0
        }
        resetHintToDefaultIfNeeded()
        window.ignoresMouseEvents = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .hidden else { return }
            self.window.orderOut(nil)
            self.statusWorkItem = nil
        }
        statusWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDConfig.dismissDelayBeforeOrderOut, execute: work)
    }

    func flashStatus(_ style: DictationHUDModel.VisualStyle, duration: TimeInterval = 1.5, autoHide: Bool = true) {
        let effectiveAutoHide = isDebugMode ? false : autoHide
        cancelHint()
        statusWorkItem?.cancel()
        pendingHint = false
        smoothedLevel = 0
        withAnimation {
            model.state = .listening
            model.controlsEnabled = false
            model.visualStyle = style
            model.level = 0
        }
        updateWindow(for: .listening)
        guard effectiveAutoHide else {
            statusWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation {
                self.model.visualStyle = .idle
                self.model.controlsEnabled = true
                self.model.state = .hidden
            }
            self.updateWindow(for: .hidden)
            self.statusWorkItem = nil
        }
        statusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func completeProcessing() {
        cancelHint()
        statusWorkItem?.cancel()
        pendingHint = false
        smoothedLevel = 0
        withAnimation {
            model.state = .listening
            model.controlsEnabled = false
            model.visualStyle = .success
            model.level = 0
        }
        updateWindow(for: .listening)

        guard !isDebugMode else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(HUDConfig.dismissCurve) {
                self.model.visualStyle = .idle
                self.model.controlsEnabled = true
                self.model.level = 0
                self.model.state = .hidden
            }
            // Let exit transition run, then order out (don’t call updateWindow here).
            let orderOutItem = DispatchWorkItem { [weak self] in
                guard let self, self.model.state == .hidden else { return }
                self.window.orderOut(nil)
                self.statusWorkItem = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + HUDConfig.dismissDuration, execute: orderOutItem)
        }
        statusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDConfig.successDuration, execute: workItem)
    }

    func updateLevel(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        DispatchQueue.main.async {
            guard self.model.controlsEnabled else { return }
            let target = clamped
            let attack: Double = 0.78
            let release: Double = 0.28
            let coefficient = target > self.smoothedLevel ? attack : release
            self.smoothedLevel += (target - self.smoothedLevel) * coefficient
            self.model.level = max(0, min(1, self.smoothedLevel))
        }
    }

    private func scheduleHint(after delay: TimeInterval, duration: TimeInterval) {
        cancelHint()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation {
                self.model.state = .hint
            }
            self.updateWindow(for: .hint)

            let hideItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.model.state == .hint {
                    withAnimation {
                        self.model.state = .hidden
                    }
                    self.resetHintToDefaultIfNeeded()
                }
                self.updateWindow(for: .hidden)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hideItem)
            self.hintWorkItem = hideItem
        }

        hintWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelHint() {
        hintWorkItem?.cancel()
        hintWorkItem = nil
    }

    private func resetHintToDefaultIfNeeded() {
        if activeHintIsCustom {
            model.hintText = defaultHintText
            activeHintIsCustom = false
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = 330
        let x = screen.visibleFrame.midX - width / 2
        let y = screen.visibleFrame.minY + 40
        window.setFrame(NSRect(x: x, y: y, width: width, height: 115), display: false)
    }

    private func updateWindow(for state: DictationHUDModel.State) {
        window.ignoresMouseEvents = state != .listening
        switch state {
        case .hidden:
            hideWindow()
        case .hint:
            window.orderFrontRegardless()
            window.setContentSize(NSSize(width: 330, height: 115))
        case .listening:
            window.orderFrontRegardless()
            let height = 115 + HUDConfig.glowRadius
            window.setContentSize(NSSize(width: 330, height: height))
        }
    }

    private func hideWindow() {
        window.orderOut(nil)
        window.ignoresMouseEvents = true
    }

    private final class DraggablePanel: NSPanel {
        private var initialLocation: NSPoint = .zero

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(clamped(frameRect), display: flag)
        }

        override func sendEvent(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown:
                initialLocation = event.locationInWindow
            case .leftMouseDragged:
                let currentLocation = event.locationInWindow
                let deltaX = currentLocation.x - initialLocation.x
                let deltaY = currentLocation.y - initialLocation.y
                var frame = self.frame
                frame.origin.x += deltaX
                frame.origin.y += deltaY
                setFrame(frame, display: false)
                // Cursor is now at (currentLocation - delta) in the new window coords; use that for next delta.
                initialLocation = NSPoint(x: currentLocation.x - deltaX, y: currentLocation.y - deltaY)
            default:
                break
            }
            super.sendEvent(event)
        }

        private func clamped(_ frame: NSRect) -> NSRect {
            guard let screen = targetScreen(for: frame) else { return frame }
            var visible = screen.visibleFrame
            let margin: CGFloat = 12
            visible = visible.insetBy(dx: margin, dy: margin)
            var clamped = frame

            if clamped.width > visible.width {
                clamped.size.width = visible.width
            }
            if clamped.height > visible.height {
                clamped.size.height = visible.height
            }

            clamped.origin.x = min(max(visible.minX, clamped.origin.x), visible.maxX - clamped.width)
            clamped.origin.y = min(max(visible.minY, clamped.origin.y), visible.maxY - clamped.height)
            return clamped
        }

        private func targetScreen(for frame: NSRect) -> NSScreen? {
            let candidates = NSScreen.screens
            return candidates.first(where: { $0.frame.intersects(frame) }) ?? self.screen ?? NSScreen.main
        }
    }
}
