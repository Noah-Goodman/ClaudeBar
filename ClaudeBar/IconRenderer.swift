import AppKit

enum IconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let canvasPx = 36

    private static func pt(_ px: Int) -> CGFloat {
        CGFloat(px) / self.scale
    }

    private static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
    }

    static func makeIcon(sessionUsed: Double?, weeklyUsed: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: self.outputSize)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: self.canvasPx,
            pixelsHigh: self.canvasPx,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return image
        }

        rep.size = self.outputSize
        image.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return image
        }
        NSGraphicsContext.current = context

        let baseFill = NSColor.labelColor
        let trackFillAlpha: CGFloat = stale ? 0.18 : 0.28
        let trackStrokeAlpha: CGFloat = stale ? 0.28 : 0.44
        let fillColor = baseFill.withAlphaComponent(stale ? 0.55 : 1.0)

        let barWidth = 30
        let barX = (self.canvasPx - barWidth) / 2

        Self.drawBar(
            x: barX, y: 19, w: barWidth, h: 12,
            fillPercent: sessionUsed,
            baseFill: baseFill, fillColor: fillColor,
            trackFillAlpha: trackFillAlpha, trackStrokeAlpha: trackStrokeAlpha,
            drawCrab: true)

        let weeklyAlpha: CGFloat = weeklyUsed != nil ? 1.0 : 0.45
        Self.drawBar(
            x: barX, y: 5, w: barWidth, h: 8,
            fillPercent: weeklyUsed,
            baseFill: baseFill, fillColor: fillColor,
            trackFillAlpha: trackFillAlpha * weeklyAlpha,
            trackStrokeAlpha: trackStrokeAlpha * weeklyAlpha,
            drawCrab: false)

        NSGraphicsContext.restoreGraphicsState()
        image.isTemplate = true
        return image
    }

    private static func drawBar(
        x: Int, y: Int, w: Int, h: Int,
        fillPercent: Double?,
        baseFill: NSColor, fillColor: NSColor,
        trackFillAlpha: CGFloat, trackStrokeAlpha: CGFloat,
        drawCrab: Bool)
    {
        let barRect = self.rect(x, y, w, h)
        let cornerRadius: CGFloat = drawCrab ? 0 : self.pt(h / 2)

        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
        baseFill.withAlphaComponent(trackFillAlpha).setFill()
        trackPath.fill()

        let inset = 1
        let strokeRect = self.rect(x + inset, y + inset, max(0, w - inset * 2), max(0, h - inset * 2))
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: max(0, cornerRadius - self.pt(inset)),
            yRadius: max(0, cornerRadius - self.pt(inset)))
        strokePath.lineWidth = CGFloat(2) / self.scale
        baseFill.withAlphaComponent(trackStrokeAlpha).setStroke()
        strokePath.stroke()

        if let fillPercent {
            let clamped = max(0, min(fillPercent / 100, 1))
            let fillWidth = max(0, min(w, Int((CGFloat(w) * clamped).rounded())))
            if fillWidth > 0 {
                NSGraphicsContext.current?.cgContext.saveGState()
                trackPath.addClip()
                fillColor.setFill()
                NSBezierPath(rect: self.rect(x, y, fillWidth, h)).fill()
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        }

        if drawCrab {
            let cgContext = NSGraphicsContext.current?.cgContext
            fillColor.setFill()

            let armSize = 3
            let armY = y + 3
            NSBezierPath(rect: self.rect(x - armSize, armY, armSize, armSize)).fill()
            NSBezierPath(rect: self.rect(x + w, armY, armSize, armSize)).fill()

            let legWidth = 2
            let legHeight = 3
            let legY = y - legHeight
            let midX = x + w / 2
            let innerGap = 4
            let outerGap = 5
            let legPositions = [
                midX - innerGap - legWidth,
                midX - innerGap - legWidth - outerGap,
                midX + innerGap,
                midX + innerGap + outerGap,
            ]
            for legX in legPositions {
                NSBezierPath(rect: self.rect(legX, legY, legWidth, legHeight)).fill()
            }

            let eyeWidth = 2
            let eyeHeight = 5
            let eyeOffset = 6
            let eyeY = y + (h - eyeHeight) / 2
            cgContext?.saveGState()
            cgContext?.setShouldAntialias(false)
            cgContext?.clear(self.rect(midX - eyeOffset - eyeWidth / 2, eyeY, eyeWidth, eyeHeight))
            cgContext?.clear(self.rect(midX + eyeOffset - eyeWidth / 2, eyeY, eyeWidth, eyeHeight))
            cgContext?.restoreGState()
        }
    }
}
