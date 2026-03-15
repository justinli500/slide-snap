import ScreenCaptureKit

struct ScreenCaptureService {

    /// Captures the main display and returns the full-screen image at native pixel resolution.
    /// Returns nil if Screen Recording permission has not been granted.
    static func captureMainDisplay() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }
}
