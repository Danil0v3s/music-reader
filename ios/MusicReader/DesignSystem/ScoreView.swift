import CoreText
import ScoreKit
import UIKit

/// Draws layout primitives with Core Text and Core Graphics. Shared by the on-screen view and PDF export.
enum ScoreRenderer {
    static func draw(_ primitives: [Primitive], in ctx: CGContext, color: (UUID?) -> UIColor) {
        for p in primitives {
            switch p {
            case .glyph(let text, let at, let size, let centered, let owner):
                drawText(text, font: Fonts.bravura(size), at: at, color: color(owner), anchor: centered ? .center : .left, in: ctx)
            case .line(let from, let to, let width, let owner):
                ctx.setStrokeColor(color(owner).cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.butt)
                ctx.move(to: from)
                ctx.addLine(to: to)
                ctx.strokePath()
            case .polygon(let points, let owner):
                guard let first = points.first else { continue }
                ctx.setFillColor(color(owner).cgColor)
                ctx.move(to: first)
                for pt in points.dropFirst() { ctx.addLine(to: pt) }
                ctx.closePath()
                ctx.fillPath()
            case .curve(let from, let to, let height, let thickness, let owner):
                // A crescent: outer curve out, inner curve back, thicker in the middle.
                let dx = to.x - from.x
                let c1 = CGPoint(x: from.x + dx * 0.25, y: from.y + height * 1.33)
                let c2 = CGPoint(x: from.x + dx * 0.75, y: to.y + height * 1.33)
                let inner = height - (height < 0 ? -thickness : thickness)
                let i1 = CGPoint(x: from.x + dx * 0.75, y: to.y + inner * 1.33)
                let i2 = CGPoint(x: from.x + dx * 0.25, y: from.y + inner * 1.33)
                ctx.setFillColor(color(owner).cgColor)
                ctx.move(to: from)
                ctx.addCurve(to: to, control1: c1, control2: c2)
                ctx.addCurve(to: from, control1: i1, control2: i2)
                ctx.fillPath()
            case .text(let text, let at, let size, let style, let anchor):
                let font: UIFont = switch style {
                case .regular: Fonts.serif(size)
                case .bold: Fonts.serif(size, weight: .bold)
                case .italic: Fonts.serif(size, italic: true)
                case .title: Fonts.serif(size, weight: .semibold)
                }
                // Stacked lines (fingerings of a chord) grow upwards, the first line lowest.
                for (i, line) in text.split(separator: "\n").enumerated() {
                    drawText(String(line), font: font, at: CGPoint(x: at.x, y: at.y - CGFloat(i) * size * 0.95), color: color(nil), anchor: anchor, in: ctx)
                }
            }
        }
    }

    private static func drawText(_ text: String, font: UIFont, at point: CGPoint, color: UIColor, anchor: Primitive.TextAnchor, in ctx: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        var x = point.x
        if anchor != .left {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            x -= anchor == .center ? width / 2 : width
        }
        ctx.saveGState()
        // UIKit contexts are flipped; flip the text matrix so glyphs stand upright on their baseline.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// The notation canvas. Lays the score out for its width and draws one tile per line of music, so a
/// playback highlight redraws one line, not the page.
final class ScoreView: UIView {
    var score: Score? { didSet { relayout() } }
    var partIndex = 0 { didSet { relayout() } }
    var staffSpace: CGFloat = 8 { didSet { if staffSpace != oldValue { relayout() } } }
    var showHeader = true { didSet { relayout() } }

    /// Per-note colours (intonation results).
    var noteColors: [UUID: UIColor] = [:] { didSet { redrawAll() } }
    var playingNote: UUID? { didSet { if playingNote != oldValue { redraw(notes: [oldValue, playingNote]) } } }
    var selectedNote: UUID? { didSet { if selectedNote != oldValue { redraw(notes: [oldValue, selectedNote]) } } }
    /// Editor caret: before item `item` of measure `measure`.
    var caret: ItemPath? { didSet { updateCaret() } }
    /// Background tint per measure (editor warnings for bars that don't add up).
    var measureTints: [Int: UIColor] = [:] { didSet { updateTints() } }

    var onTap: ((StaffHit?, CGPoint) -> Void)?
    var onLayout: ((ScoreLayout) -> Void)?

    private(set) var layout: ScoreLayout?
    private var tiles: [Tile] = []
    private var tintLayers: [CALayer] = []
    private let caretLayer = CALayer()
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.paper
        caretLayer.backgroundColor = Theme.accent.cgColor
        caretLayer.cornerRadius = 1.5
        caretLayer.isHidden = true
        layer.addSublayer(caretLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ScoreView, _) in view.redrawAll(); view.caretLayer.backgroundColor = Theme.accent.cgColor }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layout?.size.height ?? 200)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - laidOutWidth) > 0.5 { relayout() }
    }

    func relayout() {
        guard let score, bounds.width > 50, !score.parts.isEmpty else { return }
        laidOutWidth = bounds.width
        let layout = LayoutEngine.layout(score, partIndex: partIndex,
                                         options: LayoutOptions(staffSpace: staffSpace, width: bounds.width, margin: max(16, staffSpace * 2), showHeader: showHeader))
        self.layout = layout
        rebuildTiles(layout)
        invalidateIntrinsicContentSize()
        updateCaret()
        updateTints()
        onLayout?(layout)
    }

    private func rebuildTiles(_ layout: ScoreLayout) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        // Bands: the header above the first line, then one per line of music, edge to edge.
        var bands: [ClosedRange<CGFloat>] = []
        var top: CGFloat = 0
        for (i, sys) in layout.systems.enumerated() {
            if i == 0, sys.band.lowerBound > 1 { bands.append(0...sys.band.lowerBound); top = sys.band.lowerBound }
            let bottom = i + 1 < layout.systems.count ? layout.systems[i + 1].band.lowerBound : layout.size.height
            bands.append(top...bottom)
            top = bottom
        }
        if bands.isEmpty { bands = [0...layout.size.height] }
        var buckets = Array(repeating: [Primitive](), count: bands.count)
        var owners = Array(repeating: Set<UUID>(), count: bands.count)
        for p in layout.primitives {
            let (y, owner) = Self.anchor(p)
            let i = bands.firstIndex { $0.contains(y) } ?? (y < 0 ? 0 : bands.count - 1)
            buckets[i].append(p)
            if let owner { owners[i].insert(owner) }
        }
        for (i, band) in bands.enumerated() {
            let tile = Tile(primitives: buckets[i], owners: owners[i], origin: band.lowerBound, host: self)
            tile.frame = CGRect(x: 0, y: band.lowerBound, width: layout.size.width, height: band.upperBound - band.lowerBound)
            insertSubview(tile, at: 0)
            tiles.append(tile)
        }
    }

    private static func anchor(_ p: Primitive) -> (CGFloat, UUID?) {
        switch p {
        case .glyph(_, let at, _, _, let owner): (at.y, owner)
        case .line(let from, let to, _, let owner): ((from.y + to.y) / 2, owner)
        case .polygon(let pts, let owner): (pts.first?.y ?? 0, owner)
        case .curve(let from, _, _, _, let owner): (from.y, owner)
        case .text(_, let at, _, _, _): (at.y, nil)
        }
    }

    func color(for owner: UUID?) -> UIColor {
        guard let owner else { return Theme.ink }
        if owner == playingNote { return Theme.playing }
        if owner == selectedNote { return Theme.accent }
        return noteColors[owner] ?? Theme.ink
    }

    private func redrawAll() { tiles.forEach { $0.setNeedsDisplay() } }

    private func redraw(notes: [UUID?]) {
        let ids = Set(notes.compactMap { $0 })
        for t in tiles where !t.owners.isDisjoint(with: ids) { t.setNeedsDisplay() }
    }

    private func updateCaret() {
        guard let caret, let layout, let m = layout.measures.first(where: { $0.index == caret.measure }) else {
            caretLayer.isHidden = true
            return
        }
        let sys = layout.systems[m.system]
        let x: CGFloat
        if let ix = m.itemX[caret.item] { x = ix - staffSpace * 0.7 }
        else if let last = m.itemX.values.max(), caret.item > 0 { x = min(last + staffSpace * 2.4, m.frame.maxX - staffSpace * 0.6) }
        else { x = m.contentX + staffSpace * 0.4 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretLayer.isHidden = false
        caretLayer.frame = CGRect(x: x - 1.5, y: sys.staffTop - staffSpace * 1.5, width: 3, height: staffSpace * 7)
        CATransaction.commit()
    }

    private func updateTints() {
        tintLayers.forEach { $0.removeFromSuperlayer() }
        tintLayers = []
        guard let layout else { return }
        for (index, tint) in measureTints {
            guard let m = layout.measures.first(where: { $0.index == index }) else { continue }
            let sys = layout.systems[m.system]
            let l = CALayer()
            l.backgroundColor = tint.withAlphaComponent(0.13).cgColor
            l.cornerRadius = 4
            l.frame = CGRect(x: m.frame.minX, y: sys.staffTop - staffSpace, width: m.frame.width, height: staffSpace * 6)
            layer.insertSublayer(l, at: 0)
            tintLayers.append(l)
        }
    }

    /// The frame of a note's heads, for scrolling it into view.
    func frame(of noteId: UUID) -> CGRect? { layout?.noteFrames[noteId] }

    /// The whole line of music a note is on (with room above and below), for auto-scroll.
    func systemFrame(containing noteId: UUID) -> CGRect? {
        guard let layout, let f = layout.noteFrames[noteId], let sys = layout.systems.first(where: { $0.band.contains(f.midY) }) else { return nil }
        return CGRect(x: 0, y: sys.band.lowerBound, width: bounds.width, height: sys.band.upperBound - sys.band.lowerBound)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        guard let layout, let score else { onTap?(nil, p); return }
        onTap?(layout.hit(p, part: score.parts[partIndex]), p)
    }

    /// Renders the score as PDF pages (A4 by default), breaking only between lines of music.
    func pdfData(pageSize: CGSize = CGSize(width: 595, height: 842)) -> Data? {
        guard let score, !score.parts.isEmpty else { return nil }
        let margin: CGFloat = 36
        let layout = LayoutEngine.layout(score, partIndex: partIndex, options: LayoutOptions(staffSpace: 6.5, width: pageSize.width, margin: margin))
        let available = pageSize.height - 2 * margin
        var pages: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        for sys in layout.systems where sys.band.upperBound - start > available && sys.band.lowerBound > start {
            pages.append(start...sys.band.lowerBound)
            start = sys.band.lowerBound
        }
        pages.append(start...max(start, layout.size.height))
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
            for (i, page) in pages.enumerated() {
                context.beginPage()
                let ctx = context.cgContext
                ctx.saveGState()
                ctx.translateBy(x: 0, y: (i == 0 ? 0 : margin) - page.lowerBound)
                ctx.clip(to: CGRect(x: 0, y: page.lowerBound, width: pageSize.width, height: page.upperBound - page.lowerBound))
                let slice = layout.primitives.filter { page.contains(Self.anchor($0).0) }
                ScoreRenderer.draw(slice, in: ctx) { _ in .black }
                ctx.restoreGState()
            }
        }
    }

    final class Tile: UIView {
        let primitives: [Primitive]
        let owners: Set<UUID>
        let origin: CGFloat
        weak var host: ScoreView?

        init(primitives: [Primitive], owners: Set<UUID>, origin: CGFloat, host: ScoreView) {
            self.primitives = primitives
            self.owners = owners
            self.origin = origin
            self.host = host
            super.init(frame: .zero)
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            contentMode = .redraw
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext(), let host else { return }
            ctx.translateBy(x: 0, y: -origin)
            ScoreRenderer.draw(primitives, in: ctx) { host.color(for: $0) }
        }
    }
}
