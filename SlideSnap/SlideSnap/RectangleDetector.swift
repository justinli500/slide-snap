import CoreGraphics

struct SlideDetector {

    // MARK: - Configuration

    struct Config {
        var numScanLines = 15
        var colorTolerance = 25      // max channel difference for "matches background"
        var gapThreshold = 150       // max consecutive non-matching pixels before declaring edge
        var minExtent = 50           // minimum half-size of slide in pixels
        var scanBand = 400           // ±px band for spreading scan lines (pass 1)
        var gradientSnapRange = 10   // ±px to search for sharpest gradient
    }

    // MARK: - Public API

    /// Detects slide boundaries by expanding outward from `clickPoint`.
    /// The user clicks the slide's background color; the algorithm finds where that color stops.
    /// `clickPoint` is in CGImage pixel coordinates (top-left origin).
    /// Returns a rect in CGImage pixel coordinates, or nil if detection fails.
    static func detectSlide(in image: CGImage, clickPoint: CGPoint) -> CGRect? {
        guard let buffer = PixelBuffer(image: image) else { return nil }
        let config = Config()

        let cx = Int(clickPoint.x)
        let cy = Int(clickPoint.y)

        guard cx > 0, cx < buffer.width, cy > 0, cy < buffer.height else { return nil }

        // Sample the background color at the click point
        let bgColor = buffer.pixel(cx, cy)

        // --- Pass 1: Rough edges using scan lines spread ±scanBand around click ---

        let roughLeft  = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                  direction: .left, orthogonalExtent: config.scanBand, config: config)
        let roughRight = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                  direction: .right, orthogonalExtent: config.scanBand, config: config)
        let roughTop   = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                  direction: .up, orthogonalExtent: config.scanBand, config: config)
        let roughBottom = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                   direction: .down, orthogonalExtent: config.scanBand, config: config)

        print("[SlideSnap] Click pixel: (\(cx), \(cy)) in \(buffer.width)x\(buffer.height) image, bg=(\(bgColor.r),\(bgColor.g),\(bgColor.b))")
        print("[SlideSnap] Rough edges: L=\(roughLeft as Any) R=\(roughRight as Any) T=\(roughTop as Any) B=\(roughBottom as Any)")

        guard let rL = roughLeft, let rR = roughRight,
              let rT = roughTop, let rB = roughBottom else {
            print("[SlideSnap] Edge detection failed — not all edges found")
            return nil
        }

        // --- Pass 2: Refine using the rough rect's full orthogonal extent ---

        let verticalExtent   = (rB - rT) / 2
        let horizontalExtent = (rR - rL) / 2

        let left   = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .left, orthogonalExtent: verticalExtent, config: config) ?? rL
        let right  = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .right, orthogonalExtent: verticalExtent, config: config) ?? rR
        let top    = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .up, orthogonalExtent: horizontalExtent, config: config) ?? rT
        let bottom = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .down, orthogonalExtent: horizontalExtent, config: config) ?? rB

        // --- Pass 3: Gradient snap — find sharpest transition near each edge ---

        let snapLeft   = snapToGradient(buffer: buffer, edge: left, fixed: cy,
                                        direction: .left, range: config.gradientSnapRange)
        let snapRight  = snapToGradient(buffer: buffer, edge: right, fixed: cy,
                                        direction: .right, range: config.gradientSnapRange)
        let snapTop    = snapToGradient(buffer: buffer, edge: top, fixed: cx,
                                        direction: .up, range: config.gradientSnapRange)
        let snapBottom = snapToGradient(buffer: buffer, edge: bottom, fixed: cx,
                                        direction: .down, range: config.gradientSnapRange)

        let finalRect = CGRect(
            x: CGFloat(snapLeft),
            y: CGFloat(snapTop),
            width: CGFloat(snapRight - snapLeft),
            height: CGFloat(snapBottom - snapTop)
        )

        // Sanity check: must be at least minExtent in each dimension
        guard finalRect.width >= CGFloat(config.minExtent),
              finalRect.height >= CGFloat(config.minExtent) else { return nil }

        print("[SlideSnap] Detected slide: \(finalRect)")
        return finalRect
    }

    // MARK: - Scan Direction

    private enum ScanDirection {
        case left, right, up, down
    }

    // MARK: - Edge Detection (multi-line consensus with median)

    /// Scans outward from (cx, cy) in the given direction using multiple parallel scan lines
    /// spread across the orthogonal axis. Returns the median edge position.
    private static func findEdge(
        buffer: PixelBuffer,
        cx: Int, cy: Int,
        bgColor: PixelBuffer.RGB,
        direction: ScanDirection,
        orthogonalExtent: Int,
        config: Config
    ) -> Int? {
        let n = config.numScanLines
        var candidates: [Int] = []

        for i in 0..<n {
            // Spread scan lines evenly across ±orthogonalExtent
            let offset = -orthogonalExtent + (2 * orthogonalExtent * i) / max(n - 1, 1)

            let edgePos: Int?
            switch direction {
            case .left:
                let scanY = clamp(cy + offset, 0, buffer.height - 1)
                edgePos = scanForColorEdge(buffer: buffer, startX: cx, y: scanY,
                                           dx: -1, bgColor: bgColor, config: config)
            case .right:
                let scanY = clamp(cy + offset, 0, buffer.height - 1)
                edgePos = scanForColorEdge(buffer: buffer, startX: cx, y: scanY,
                                           dx: 1, bgColor: bgColor, config: config)
            case .up:
                let scanX = clamp(cx + offset, 0, buffer.width - 1)
                edgePos = scanForColorEdge(buffer: buffer, x: scanX, startY: cy,
                                           dy: -1, bgColor: bgColor, config: config)
            case .down:
                let scanX = clamp(cx + offset, 0, buffer.width - 1)
                edgePos = scanForColorEdge(buffer: buffer, x: scanX, startY: cy,
                                           dy: 1, bgColor: bgColor, config: config)
            }

            if let pos = edgePos {
                candidates.append(pos)
            }
        }

        // Need at least half the scan lines to agree
        guard candidates.count >= n / 2 else { return nil }

        candidates.sort()
        return candidates[candidates.count / 2]  // median
    }

    // MARK: - Horizontal color edge scan

    /// Scans horizontally from (startX, y) in direction dx (±1).
    /// Tracks the last position where the background color was seen.
    /// Returns that position once `gapThreshold` consecutive non-matching pixels are encountered.
    private static func scanForColorEdge(
        buffer: PixelBuffer,
        startX: Int, y: Int,
        dx: Int,
        bgColor: PixelBuffer.RGB,
        config: Config
    ) -> Int? {
        let tol = config.colorTolerance
        var lastMatchX = startX
        var gap = 0
        var x = startX

        while x >= 0 && x < buffer.width {
            let p = buffer.pixel(x, y)
            if abs(p.r - bgColor.r) <= tol &&
               abs(p.g - bgColor.g) <= tol &&
               abs(p.b - bgColor.b) <= tol {
                lastMatchX = x
                gap = 0
            } else {
                gap += 1
                if gap >= config.gapThreshold {
                    // Only accept if we've moved at least minExtent from click
                    if abs(lastMatchX - startX) >= config.minExtent {
                        return lastMatchX
                    }
                    return nil
                }
            }
            x += dx
        }

        // Reached image boundary — use last match if far enough from click
        if abs(lastMatchX - startX) >= config.minExtent {
            return lastMatchX
        }
        return nil
    }

    // MARK: - Vertical color edge scan

    /// Scans vertically from (x, startY) in direction dy (±1).
    /// Tracks the last position where the background color was seen.
    /// Returns that position once `gapThreshold` consecutive non-matching pixels are encountered.
    private static func scanForColorEdge(
        buffer: PixelBuffer,
        x: Int, startY: Int,
        dy: Int,
        bgColor: PixelBuffer.RGB,
        config: Config
    ) -> Int? {
        let tol = config.colorTolerance
        var lastMatchY = startY
        var gap = 0
        var y = startY

        while y >= 0 && y < buffer.height {
            let p = buffer.pixel(x, y)
            if abs(p.r - bgColor.r) <= tol &&
               abs(p.g - bgColor.g) <= tol &&
               abs(p.b - bgColor.b) <= tol {
                lastMatchY = y
                gap = 0
            } else {
                gap += 1
                if gap >= config.gapThreshold {
                    if abs(lastMatchY - startY) >= config.minExtent {
                        return lastMatchY
                    }
                    return nil
                }
            }
            y += dy
        }

        if abs(lastMatchY - startY) >= config.minExtent {
            return lastMatchY
        }
        return nil
    }

    // MARK: - Gradient Snap

    /// Walks ±range pixels around `edge` and snaps to the position with the sharpest
    /// color gradient (largest difference between adjacent pixels).
    private static func snapToGradient(
        buffer: PixelBuffer,
        edge: Int,
        fixed: Int,
        direction: ScanDirection,
        range: Int
    ) -> Int {
        var bestPos = edge
        var bestGrad = 0

        let lo = edge - range
        let hi = edge + range

        switch direction {
        case .left, .right:
            let y = clamp(fixed, 0, buffer.height - 1)
            for x in max(1, lo)...min(buffer.width - 1, hi) {
                let a = buffer.pixel(x - 1, y)
                let b = buffer.pixel(x, y)
                let grad = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                if grad > bestGrad {
                    bestGrad = grad
                    bestPos = x
                }
            }
        case .up, .down:
            let x = clamp(fixed, 0, buffer.width - 1)
            for y in max(1, lo)...min(buffer.height - 1, hi) {
                let a = buffer.pixel(x, y - 1)
                let b = buffer.pixel(x, y)
                let grad = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                if grad > bestGrad {
                    bestGrad = grad
                    bestPos = y
                }
            }
        }

        return bestPos
    }

    // MARK: - Helpers

    private static func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), hi)
    }
}

// MARK: - PixelBuffer

/// Fast random-access wrapper around raw RGBA pixel data from a CGImage.
private struct PixelBuffer {
    let width: Int
    let height: Int
    private let data: [UInt8]
    private let bytesPerRow: Int

    struct RGB {
        let r: Int, g: Int, b: Int
    }

    init?(image: CGImage) {
        self.width = image.width
        self.height = image.height
        let bpp = 4
        self.bytesPerRow = width * bpp

        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGContext draws CGImages "upside down" (bottom-left origin), which means
        // CGImage row 0 (top) lands at buffer row 0. No flip needed — buffer row
        // order naturally matches CGImage row order.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        self.data = pixels
    }

    /// Returns the RGB values at (x, y). No bounds checking for performance.
    func pixel(_ x: Int, _ y: Int) -> RGB {
        let offset = y * bytesPerRow + x * 4
        return RGB(r: Int(data[offset]), g: Int(data[offset + 1]), b: Int(data[offset + 2]))
    }
}
