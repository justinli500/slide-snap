import Carbon
import Cocoa
import Sparkle
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
    private var hotKeyRef: EventHotKeyRef?
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotkey()
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
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)
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

    // MARK: Hotkey (Carbon — consumes the event system-wide, no alert beep)

    private func setupHotkey() {
        // Install a handler for hot key events
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                print("[SlideSnap] Hotkey triggered!")
                delegate.triggerCapture()
                return noErr
            },
            1, &eventType, selfPtr, nil
        )

        // Register ⌘⇧2 as a global hotkey
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4150), id: UInt32(1))
        RegisterEventHotKey(
            UInt32(kVK_ANSI_2),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
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
