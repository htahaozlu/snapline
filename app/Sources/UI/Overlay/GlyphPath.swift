import AppKit
import CoreText

/// A single line of text as one vector path (docs/DESIGN.md §9, plate text).
///
/// The plate draws its label with a CAShapeLayer instead of a CATextLayer: a text layer is
/// rasterised inside Nokta (a backing store plus ColorSync transforms that stay resident after
/// the plate hides — measured ≈ 2 MB with `--bench-used`), a shape layer is filled by the render
/// server. The path is in y-down coordinates with its top at 0, matching the flipped overlay tree.
enum GlyphPath {
    struct Line {
        let path: CGPath
        /// Typographic width (advance), points.
        let width: CGFloat
        /// ascent + descent, points.
        let height: CGFloat
    }

    /// `string` set in `font`, truncated with "…" to `maxWidth` when given.
    static func line(_ string: String, font: NSFont, maxWidth: CGFloat? = nil) -> Line {
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        var ctLine = CTLineCreateWithAttributedString(attributed)
        if let maxWidth, CTLineGetTypographicBounds(ctLine, nil, nil, nil) > Double(maxWidth) {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font]))
            ctLine = CTLineCreateTruncatedLine(ctLine, Double(maxWidth), .end, token) ?? ctLine
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let path = CGMutablePath()
        // y-down: baseline at `ascent`, glyph outlines flipped about it.
        let flip = CGAffineTransform(translationX: 0, y: ascent).scaledBy(x: 1, y: -1)
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName as String].map({ $0 as! CTFont }) else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                let place = CGAffineTransform(translationX: positions[i].x, y: positions[i].y).concatenating(flip)
                path.addPath(outline, transform: place)
            }
        }
        return Line(path: path, width: ceil(width), height: ceil(ascent + descent))
    }
}
