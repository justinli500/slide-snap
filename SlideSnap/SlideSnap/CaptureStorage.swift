import Cocoa

struct CaptureStorage {

    private static var capturesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlideSnap")
    }

    /// Crops the selected rectangle from the screenshot, copies it to the clipboard,
    /// and saves it as a PNG to ~/Documents/SlideSnap/.
    static func saveCapture(from image: CGImage, rect: CGRect) {
        // rect is already in CGImage pixel coordinates (top-left origin)
        guard let cropped = image.cropping(to: rect) else { return }

        // Copy to clipboard (Universal Clipboard compatible)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        pasteboard.writeObjects([nsImage])

        // Save to disk
        let dir = capturesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "SlideSnap_\(formatter.string(from: Date())).png"
        let fileURL = dir.appendingPathComponent(filename)

        let rep = NSBitmapImageRep(cgImage: cropped)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL)
        }
    }

    /// Opens the captures folder in Finder.
    static func openCapturesFolder() {
        let dir = capturesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
