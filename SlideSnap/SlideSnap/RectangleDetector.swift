import CoreGraphics

struct SlideDetector {

    // MARK: - Configuration

    struct Config {
        var numScanLines = 15
        var colorTolerance = 25      // max channel difference for "matches background"
        var minExtent = 20           // minimum distance from click to declare an edge
        var scanBand = 200           // ±px band for spreading scan lines (pass 1)
        var gradientSnapRange = 10   // ±px to search for sharpest gradient
        var sampleRadius = 2         // neighborhood half-size for background color sampling (in steps)
        var sampleStep = 8           // pixel spacing for background color sampling grid
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

        // Sample a neighborhood around the click to find the dominant background color.
        // This handles the case where the user clicks on text/content instead of bare background.
        let bgColor = sampleBackgroundColor(buffer: buffer, cx: cx, cy: cy, config: config)

        // --- Pass 1: Rough edges (generous edgeConfirm to bridge over text) ---

        let roughLeft  = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                  direction: .left, orthogonalExtent: config.scanBand, edgeConfirm: 20, config: config)
        let roughRight = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                  direction: .right, orthogonalExtent: config.scanBand, edgeConfirm: 20, config: config)
        let roughTop   = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                  direction: .up, orthogonalExtent: config.scanBand, edgeConfirm: 20, config: config)
        let roughBottom = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                                   direction: .down, orthogonalExtent: config.scanBand, edgeConfirm: 20, config: config)

        print("[SlideSnap] Click pixel: (\(cx), \(cy)) in \(buffer.width)x\(buffer.height) image, bg=(\(bgColor.r),\(bgColor.g),\(bgColor.b))")
        print("[SlideSnap] Rough edges: L=\(roughLeft as Any) R=\(roughRight as Any) T=\(roughTop as Any) B=\(roughBottom as Any)")

        guard let rL = roughLeft, let rR = roughRight,
              let rT = roughTop, let rB = roughBottom else {
            print("[SlideSnap] Edge detection failed — not all edges found")
            return nil
        }

        // --- Pass 2: Refine with margin probes (edgeConfirm=2 detects separators) ---

        let verticalExtent   = (rB - rT) / 2
        let horizontalExtent = (rR - rL) / 2

        let left   = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .left, orthogonalExtent: verticalExtent, edgeConfirm: 2, config: config) ?? rL
        let right  = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .right, orthogonalExtent: verticalExtent, edgeConfirm: 2, config: config) ?? rR
        let top    = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .up, orthogonalExtent: horizontalExtent, edgeConfirm: 2, config: config) ?? rT
        let bottom = findEdge(buffer: buffer, cx: cx, cy: cy, bgColor: bgColor,
                              direction: .down, orthogonalExtent: horizontalExtent, edgeConfirm: 2, config: config) ?? rB

        // --- Pass 3: Boundary snap — search inward from each edge for the strongest
        //     gradient that has bgColor on its inside, correcting any overshoot ---

        let snapLeft   = snapToBoundary(buffer: buffer, edge: left, fixed: cy,
                                        direction: .left, bgColor: bgColor, config: config)
        let snapRight  = snapToBoundary(buffer: buffer, edge: right, fixed: cy,
                                        direction: .right, bgColor: bgColor, config: config)
        let snapTop    = snapToBoundary(buffer: buffer, edge: top, fixed: cx,
                                        direction: .up, bgColor: bgColor, config: config)
        let snapBottom = snapToBoundary(buffer: buffer, edge: bottom, fixed: cx,
                                        direction: .down, bgColor: bgColor, config: config)

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

    // MARK: - Background Color Sampling

    /// Samples a grid of pixels around the click point and returns the dominant color.
    /// This makes detection robust even when the user clicks on text or content
    /// rather than bare background — the surrounding pixels are mostly background.
    private static func sampleBackgroundColor(
        buffer: PixelBuffer, cx: Int, cy: Int, config: Config
    ) -> PixelBuffer.RGB {
        let step = config.sampleStep
        let radius = config.sampleRadius
        let tol = config.colorTolerance
        var samples: [PixelBuffer.RGB] = []

        for dy in -radius...radius {
            for dx in -radius...radius {
                let sx = clamp(cx + dx * step, 0, buffer.width - 1)
                let sy = clamp(cy + dy * step, 0, buffer.height - 1)
                samples.append(buffer.pixel(sx, sy))
            }
        }

        // Find the sample whose color has the most matches among all samples
        var bestIndex = 0
        var bestCount = 0

        for i in 0..<samples.count {
            var count = 0
            for j in 0..<samples.count {
                if abs(samples[i].r - samples[j].r) <= tol &&
                   abs(samples[i].g - samples[j].g) <= tol &&
                   abs(samples[i].b - samples[j].b) <= tol {
                    count += 1
                }
            }
            if count > bestCount {
                bestCount = count
                bestIndex = i
            }
        }

        return samples[bestIndex]
    }

    // MARK: - Edge Detection (cross-validated consensus)

    /// Sweeps outward from (cx, cy) one position at a time, checking ALL scan lines
    /// at each position. Declares the edge when the background color disappears from
    /// all scan lines simultaneously (indicating a separator or real slide boundary).
    ///
    /// This approach naturally bridges over images and content (which only block SOME
    /// scan lines) while stopping at separators (which block ALL scan lines).
    private static func findEdge(
        buffer: PixelBuffer,
        cx: Int, cy: Int,
        bgColor: PixelBuffer.RGB,
        direction: ScanDirection,
        orthogonalExtent: Int,
        edgeConfirm: Int,
        config: Config
    ) -> Int? {
        let n = config.numScanLines
        let tol = config.colorTolerance
        let minMatchCount = 1  // at least 1 scan line must see bg to be "inside slide"

        // Compute orthogonal scan line positions (evenly spread)
        var scanPositions: [Int] = []
        for i in 0..<n {
            let offset = -orthogonalExtent + (2 * orthogonalExtent * i) / max(n - 1, 1)
            switch direction {
            case .left, .right:
                scanPositions.append(clamp(cy + offset, 0, buffer.height - 1))
            case .up, .down:
                scanPositions.append(clamp(cx + offset, 0, buffer.width - 1))
            }
        }

        // Add margin probe lines near the edges of the orthogonal extent.
        // These ensure bg is detected at the slide margins even when text/content
        // spans most (but not all) of the slide width — distinguishing content from separators.
        let marginInset = 15
        switch direction {
        case .left, .right:
            scanPositions.append(clamp(cy - orthogonalExtent + marginInset, 0, buffer.height - 1))
            scanPositions.append(clamp(cy + orthogonalExtent - marginInset, 0, buffer.height - 1))
        case .up, .down:
            scanPositions.append(clamp(cx - orthogonalExtent + marginInset, 0, buffer.width - 1))
            scanPositions.append(clamp(cx + orthogonalExtent - marginInset, 0, buffer.width - 1))
        }

        // Determine scan parameters
        let start: Int
        let step: Int
        let limit: Int
        switch direction {
        case .left:  start = cx; step = -1; limit = 0
        case .right: start = cx; step = 1;  limit = buffer.width - 1
        case .up:    start = cy; step = -1; limit = 0
        case .down:  start = cy; step = 1;  limit = buffer.height - 1
        }

        var lastGoodPos = start
        var consecutiveLow = 0
        var pos = start

        while (step > 0 && pos <= limit) || (step < 0 && pos >= limit) {
            // Count how many scan lines see bgColor at this position
            var matchCount = 0
            for orthoPos in scanPositions {
                let p: PixelBuffer.RGB
                switch direction {
                case .left, .right: p = buffer.pixel(pos, orthoPos)
                case .up, .down:    p = buffer.pixel(orthoPos, pos)
                }
                if abs(p.r - bgColor.r) <= tol &&
                   abs(p.g - bgColor.g) <= tol &&
                   abs(p.b - bgColor.b) <= tol {
                    matchCount += 1
                }
            }

            if matchCount >= minMatchCount {
                // Background visible on at least one scan line → still inside slide
                lastGoodPos = pos
                consecutiveLow = 0
            } else {
                // No scan lines see background → separator or edge
                consecutiveLow += 1
                if consecutiveLow >= edgeConfirm {
                    break
                }
            }

            pos += step
        }

        // Check minimum extent from click
        if abs(lastGoodPos - start) >= config.minExtent {
            return lastGoodPos
        }
        return nil
    }

    // MARK: - Boundary Snap

    /// Searches from the detected edge inward (toward the click point) for a gradient
    /// that marks the actual slide boundary. Validates candidates by checking that
    /// the background color is dense on the inward side of the gradient.
    /// Falls back to simple strongest-gradient if no validated candidate is found.
    private static func snapToBoundary(
        buffer: PixelBuffer,
        edge: Int,
        fixed: Int,
        direction: ScanDirection,
        bgColor: PixelBuffer.RGB,
        config: Config
    ) -> Int {
        let outwardRange = config.gradientSnapRange   // 10px outward (fine-tune)
        let inwardRange = 80                          // 80px inward (correct overshoot)
        let tol = config.colorTolerance
        let densityWindow = 20                        // check bgColor in 20px past gradient
        let minGrad = 30                              // minimum gradient to consider

        var bestPos = edge
        var bestScore: Double = 0
        // Fallback: strongest gradient regardless of bgColor check
        var fallbackPos = edge
        var fallbackGrad = 0

        switch direction {
        case .left, .right:
            let y = clamp(fixed, 0, buffer.height - 1)
            // "inward" = toward click = opposite of scan direction
            let inwardDx = (direction == .left) ? 1 : -1
            let lo = min(edge - inwardDx * outwardRange, edge + inwardDx * inwardRange)
            let hi = max(edge - inwardDx * outwardRange, edge + inwardDx * inwardRange)

            for x in max(1, lo)...min(buffer.width - 1, hi) {
                let a = buffer.pixel(x - 1, y)
                let b = buffer.pixel(x, y)
                let grad = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)

                if grad > fallbackGrad {
                    fallbackGrad = grad
                    fallbackPos = x
                }

                guard grad >= minGrad else { continue }

                // Check bgColor density on the inward side
                let insidePixel = (direction == .left) ? b : a
                guard abs(insidePixel.r - bgColor.r) <= tol &&
                      abs(insidePixel.g - bgColor.g) <= tol &&
                      abs(insidePixel.b - bgColor.b) <= tol else { continue }

                // Validate: bgColor should be dense for the next densityWindow pixels inward
                var matchCount = 0
                for d in 1...densityWindow {
                    let vx = x + inwardDx * d
                    guard vx >= 0, vx < buffer.width else { break }
                    let p = buffer.pixel(vx, y)
                    if abs(p.r - bgColor.r) <= tol &&
                       abs(p.g - bgColor.g) <= tol &&
                       abs(p.b - bgColor.b) <= tol {
                        matchCount += 1
                    }
                }

                let density = Double(matchCount) / Double(densityWindow)
                let score = Double(grad) * density
                if score > bestScore {
                    bestScore = score
                    bestPos = x
                }
            }

        case .up, .down:
            let x = clamp(fixed, 0, buffer.width - 1)
            let inwardDy = (direction == .up) ? 1 : -1
            let lo = min(edge - inwardDy * outwardRange, edge + inwardDy * inwardRange)
            let hi = max(edge - inwardDy * outwardRange, edge + inwardDy * inwardRange)

            for y in max(1, lo)...min(buffer.height - 1, hi) {
                let a = buffer.pixel(x, y - 1)
                let b = buffer.pixel(x, y)
                let grad = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)

                if grad > fallbackGrad {
                    fallbackGrad = grad
                    fallbackPos = y
                }

                guard grad >= minGrad else { continue }

                let insidePixel = (direction == .up) ? b : a
                guard abs(insidePixel.r - bgColor.r) <= tol &&
                      abs(insidePixel.g - bgColor.g) <= tol &&
                      abs(insidePixel.b - bgColor.b) <= tol else { continue }

                var matchCount = 0
                for d in 1...densityWindow {
                    let vy = y + inwardDy * d
                    guard vy >= 0, vy < buffer.height else { break }
                    let p = buffer.pixel(x, vy)
                    if abs(p.r - bgColor.r) <= tol &&
                       abs(p.g - bgColor.g) <= tol &&
                       abs(p.b - bgColor.b) <= tol {
                        matchCount += 1
                    }
                }

                let density = Double(matchCount) / Double(densityWindow)
                let score = Double(grad) * density
                if score > bestScore {
                    bestScore = score
                    bestPos = y
                }
            }
        }

        // Use validated boundary if found, otherwise fall back to strongest gradient
        return bestScore > 0 ? bestPos : fallbackPos
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
