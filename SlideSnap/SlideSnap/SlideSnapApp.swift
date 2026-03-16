import Cocoa
import SwiftUI

@main
struct SlideSnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotkeyMonitors()
    }

    // MARK: Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "SlideSnap")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture Slide  ⌘⇧2", action: #selector(captureSlideAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Captures Folder", action: #selector(openCapturesFolderAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func captureSlideAction() {
        triggerCapture()
    }

    @objc private func openCapturesFolderAction() {
        CaptureStorage.openCapturesFolder()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Hotkey

    private func setupHotkeyMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
            return event
        }
    }

    private func handleHotkey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 19,
              flags.contains([.command, .shift])
        else { return }

        print("[SlideSnap] Hotkey triggered!")
        triggerCapture()
    }

    // MARK: Capture flow

    func triggerCapture() {
        print("[SlideSnap] Starting capture...")

        // Overlay shows the dim immediately; screenshot loads in the background
        OverlayWindow.show(
            onSelect: { selectedRect, screenshot in
                print("[SlideSnap] Slide selected: \(selectedRect)")
                CaptureStorage.saveCapture(from: screenshot, rect: selectedRect)
            },
            onCancel: {
                print("[SlideSnap] Cancelled")
            }
        )
    }
}
