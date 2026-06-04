import AppKit
import Darwin
import Foundation
import VXLib

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var coordinator: AppCoordinator?
    private let watchdogQueue = DispatchQueue(label: "com.vx.watchdog")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logEnvironmentDiagnostics()
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        coordinator = AppCoordinator(appState: appState)
        startMainThreadWatchdog()
    }

    /// Safety net for a wedged main thread. vx is an accessory (menu-bar) app, so a hung
    /// process never appears in Force Quit — the only recourse would otherwise be Activity
    /// Monitor. If the main thread stops servicing work for `timeout` seconds (far longer
    /// than any legitimate operation — transcription runs in a subprocess, off-main),
    /// self-terminate so the process can't become an un-quittable zombie.
    private func startMainThreadWatchdog() {
        let q = watchdogQueue
        let interval: TimeInterval = 3
        let timeout: TimeInterval = 12
        func tick() {
            let sema = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { sema.signal() }
            if sema.wait(timeout: .now() + timeout) == .timedOut {
                NSLog("[vx-ui] WATCHDOG: main thread unresponsive for %.0fs — killing the process to avoid a wedged, un-force-quittable app.", timeout)
                kill(getpid(), SIGKILL)
            }
            q.asyncAfter(deadline: .now() + interval) { tick() }
        }
        q.async { tick() }
    }

    /// Installs a minimal main menu so that standard text-editing keyboard shortcuts
    /// (Cmd+V, Cmd+C, Cmd+X, Cmd+A, Cmd+Z) are dispatched through the responder chain
    /// to focused text fields and editors. Accessory-policy apps have no menu bar
    /// visible to the user, but NSApp.mainMenu is still required for shortcut routing.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (must be first item — AppKit always treats index 0 as the app menu)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit vx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // Edit menu — provides the responder-chain targets for text editing shortcuts
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.invalidate()
    }

    private func logEnvironmentDiagnostics() {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        NSLog("[vx-ui] CWD: \(cwd)")

        let modelURL = ResourceLocator.modelURL()
        let modelExists = fm.fileExists(atPath: modelURL.path)
        NSLog("[vx-ui] Model path: \(modelURL.path) exists: \(modelExists)")

        let backendURL = ResourceLocator.backendExecutableURL()
        let backendExists = fm.fileExists(atPath: backendURL.path)
        let backendExecutable = fm.isExecutableFile(atPath: backendURL.path)
        NSLog("[vx-ui] Backend path: \(backendURL.path) exists: \(backendExists) executable: \(backendExecutable)")
    }
}
