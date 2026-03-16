import Cocoa

// MARK: - OverlayWindow

final class OverlayWindow: NSWindow {

    override var canBecomeKey: Bool { true }

    /// Shows a full-screen dimmed overlay immediately, then loads the screenshot
    /// in the background. User clicks inside a slide to auto-detect its boundaries,
    /// or drags to select manually. Press Esc to cancel.
    static func show(
        onSelect: @escaping (CGRect, CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard let screen = NSScreen.main else { return }

        // Remember which app was active so we can restore focus after closing
        let previousApp = NSWorkspace.shared.frontmostApplication

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        // Exclude this window from screen captures so the screenshot doesn't include the dim
        window.sharingType = .none

        let overlayView = OverlayView(
            frame: screen.frame,
            onSelect: { pixelRect, screenshot in
                previousApp?.activate()
                window.close()
                onSelect(pixelRect, screenshot)
            },
            onCancel: {
                previousApp?.activate()
                window.close()
                onCancel()
            }
        )

        window.contentView = overlayView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Capture the screenshot in the background — the overlay is already visible
        Task {
            guard let screenshot = await ScreenCaptureService.captureMainDisplay() else {
                previousApp?.activate()
                window.close()
                return
            }
            overlayView.setScreenshot(screenshot)
        }
    }
}

// MARK: - OverlayView

private final class OverlayView: NSView {

    private var screenshot: CGImage?
    private let onSelect: (CGRect, CGImage) -> Void
    private let onCancel: () -> Void

    // Scale computed from actual screenshot dimensions vs view size.
    private var imageScaleX: CGFloat = 1
    private var imageScaleY: CGFloat = 1

    // Drag-to-select state
    private var dragStart: NSPoint? = nil
    private var dragCurrent: NSPoint? = nil
    private var isDragging = false

    // Flash highlight after detection
    private var detectedViewRect: CGRect? = nil

    init(
        frame: NSRect,
        onSelect: @escaping (CGRect, CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel

        super.init(frame: frame)

        let trackingArea = NSTrackingArea(
            rect: frame,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Called when the screenshot is ready. Updates the view to show the captured screen.
    func setScreenshot(_ image: CGImage) {
        self.screenshot = image
        imageScaleX = CGFloat(image.width) / bounds.width
        imageScaleY = CGFloat(image.height) / bounds.height
        print("[SlideSnap] Screenshot loaded: \(image.width)x\(image.height), Scale: \(imageScaleX)x\(imageScaleY)")
        needsDisplay = true
    }

    // MARK: Coordinate Conversion

    /// Converts an NSView point to CGImage pixel coordinates (top-left origin).
    private func viewPointToPixelPoint(_ viewPoint: NSPoint) -> CGPoint {
        CGPoint(
            x: viewPoint.x * imageScaleX,
            y: (bounds.height - viewPoint.y) * imageScaleY
        )
    }

    /// Converts a CGImage pixel rect (top-left origin) to NSView point rect (bottom-left origin).
    private func pixelRectToViewRect(_ pixelRect: CGRect) -> CGRect {
        let viewHeight = bounds.height
        return CGRect(
            x: pixelRect.origin.x / imageScaleX,
            y: viewHeight - (pixelRect.origin.y + pixelRect.height) / imageScaleY,
            width: pixelRect.width / imageScaleX,
            height: pixelRect.height / imageScaleY
        )
    }

    /// Converts an NSView rect (bottom-left origin) to CGImage pixel rect (top-left origin).
    private func viewRectToPixelRect(_ viewRect: CGRect) -> CGRect {
        let viewHeight = bounds.height
        return CGRect(
            x: viewRect.origin.x * imageScaleX,
            y: (viewHeight - viewRect.origin.y - viewRect.height) * imageScaleY,
            width: viewRect.width * imageScaleX,
            height: viewRect.height * imageScaleY
        )
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw the screenshot as background (if loaded), otherwise transparent
        if let screenshot = screenshot {
            ctx.draw(screenshot, in: bounds)
        }

        // 2. Draw dimmed overlay (always — gives instant visual feedback)
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        // 3. Draw drag selection rectangle if dragging
        if let screenshot = screenshot, let start = dragStart, let current = dragCurrent, isDragging {
            let selectionRect = rectFromPoints(start, current)

            // Cut through dim for the selection area
            ctx.saveGState()
            ctx.clip(to: [selectionRect])
            ctx.draw(screenshot, in: bounds)
            ctx.restoreGState()

            // Draw selection border
            NSColor.systemGreen.setStroke()
            let selPath = NSBezierPath(rect: selectionRect)
            selPath.lineWidth = 3.0
            selPath.setLineDash([8, 4], count: 2, phase: 0)
            selPath.stroke()
        }

        // 4. Draw detected slide highlight (green flash)
        if let screenshot = screenshot, let viewRect = detectedViewRect {
            ctx.saveGState()
            ctx.clip(to: [viewRect])
            ctx.draw(screenshot, in: bounds)
            ctx.restoreGState()

            NSColor.systemGreen.setStroke()
            let borderPath = NSBezierPath(rect: viewRect.insetBy(dx: -1, dy: -1))
            borderPath.lineWidth = 4.0
            borderPath.stroke()
        }
    }

    private func rectFromPoints(_ p1: NSPoint, _ p2: NSPoint) -> NSRect {
        NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
    }

    // MARK: Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard screenshot != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = point

        // Start dragging after 5pt threshold
        if let start = dragStart {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if sqrt(dx*dx + dy*dy) > 5 {
                isDragging = true
            }
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let screenshot = screenshot else { return }
        let point = convert(event.locationInWindow, from: nil)

        if isDragging, let start = dragStart {
            // Drag-to-select: convert the drawn rect to image pixel coords
            let selectionRect = rectFromPoints(start, point)
            guard selectionRect.width > 10, selectionRect.height > 10 else {
                resetDrag()
                return
            }
            let pixelRect = viewRectToPixelRect(selectionRect)
            print("[SlideSnap] Manual select: view=\(selectionRect) → pixel=\(pixelRect)")
            onSelect(pixelRect, screenshot)
        } else {
            // Click-to-detect: run SlideDetector from click point
            let pixelPoint = viewPointToPixelPoint(point)
            print("[SlideSnap] Click at view=\(point), pixel=\(pixelPoint)")

            if let detected = SlideDetector.detectSlide(in: screenshot, clickPoint: pixelPoint) {
                // Show green highlight briefly, then select
                detectedViewRect = pixelRectToViewRect(detected)
                needsDisplay = true

                let capturedRect = detected
                let img = screenshot
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.onSelect(capturedRect, img)
                }
            } else {
                print("[SlideSnap] No slide detected at click point — try again")
                // Keep overlay open so user can try another click
            }
        }

        resetDrag()
    }

    private func resetDrag() {
        dragStart = nil
        dragCurrent = nil
        isDragging = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: Keyboard handling

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel()
        }
    }
}
