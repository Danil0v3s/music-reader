import UIKit

/// The sign-in screen's motion: the four cello strings, plucked one after another (C, G, D, A, 1.2 s apart,
/// a 4.8 s loop). A plucked string swells into a pale varnish lens that rings down, shimmering, while its name
/// lights up. With Reduce Motion on, the strings simply rest.
final class StringsView: UIView {
    private struct Strand {
        let label = CATextLayer()
        let line = CAShapeLayer()
        let ring = CALayer()
        let lens = CAShapeLayer()
    }

    private let names = ["A", "D", "G", "C"]          // top to bottom
    private let widths: [CGFloat] = [1, 1.4, 1.8, 2.2]
    private let period: CFTimeInterval = 4.8
    private var strands: [Strand] = []
    private let nut = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "The four cello strings, plucked one after another"
        accessibilityTraits = .image
        layer.addSublayer(nut)
        for (i, name) in names.enumerated() {
            let s = Strand()
            s.label.string = name
            s.label.font = Fonts.label(13, weight: .bold)
            s.label.fontSize = 13
            s.label.alignmentMode = .left
            s.label.contentsScale = UIScreen.main.scale
            s.line.lineWidth = widths[i]
            s.ring.addSublayer(s.lens)
            [s.ring, s.line, s.label].forEach(layer.addSublayer)
            strands.append(s)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StringsView, _) in view.applyColors() }
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restart), name: UIApplication.willEnterForegroundNotification, object: nil)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 176) }

    private func applyColors() {
        let t = traitCollection
        nut.backgroundColor = Theme.ink.resolvedColor(with: t).withAlphaComponent(0.35).cgColor
        for s in strands {
            s.line.strokeColor = Theme.ink.resolvedColor(with: t).withAlphaComponent(0.55).cgColor
            s.lens.fillColor = Theme.accent.resolvedColor(with: t).withAlphaComponent(0.13).cgColor
            s.label.foregroundColor = Theme.inkSoft.resolvedColor(with: t).cgColor
        }
        restart()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height, w = bounds.width
        let top: CGFloat = 24 / 176 * h, step = (h - 2 * top) / 3
        let x0: CGFloat = 26, x1 = w - 8
        nut.frame = CGRect(x: 22, y: top - 10, width: 3, height: 3 * step + 20)
        for (i, s) in strands.enumerated() {
            let y = top + CGFloat(i) * step
            let swell = 12 + CGFloat(i) * 3.5          // lower strings swing wider
            s.label.frame = CGRect(x: 0, y: y - 9, width: 16, height: 18)
            let line = UIBezierPath()
            line.move(to: CGPoint(x: x0, y: y))
            line.addLine(to: CGPoint(x: x1, y: y))
            s.line.path = line.cgPath
            s.ring.frame = CGRect(x: x0, y: y - swell, width: x1 - x0, height: 2 * swell)
            s.lens.frame = s.ring.bounds
            let lens = UIBezierPath()
            let mid = s.ring.bounds.width / 2
            lens.move(to: CGPoint(x: 0, y: swell))
            lens.addQuadCurve(to: CGPoint(x: 2 * mid, y: swell), controlPoint: CGPoint(x: mid, y: -swell))
            lens.addQuadCurve(to: CGPoint(x: 0, y: swell), controlPoint: CGPoint(x: mid, y: 3 * swell))
            s.lens.path = lens.cgPath
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    @objc private func restart() {
        for s in strands { [s.ring, s.lens, s.label].forEach { $0.removeAllAnimations() } }
        let still = UIAccessibility.isReduceMotionEnabled || window == nil
        for s in strands { s.ring.transform = CATransform3DMakeScale(1, 0, 1) }
        guard !still else { return }

        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let rest = Theme.inkSoft.resolvedColor(with: traitCollection).cgColor
        let lit = Theme.accent.resolvedColor(with: traitCollection).cgColor
        // C (the bottom string) first, then G, D, A.
        for (i, s) in strands.reversed().enumerated() {
            let begin = now + Double(i) * period / 4

            let ring = CAKeyframeAnimation(keyPath: "transform.scale.y")
            ring.values = [0, 1, 0.42, 0.12, 0]
            ring.keyTimes = [0, 0.05, 0.3, 0.6, 1]
            ring.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1), count: 4)
            add(ring, to: s.ring, begin: begin, fill: .backwards)

            let shimmer = CABasicAnimation(keyPath: "transform.scale.y")
            shimmer.fromValue = 1
            shimmer.toValue = 0.5
            shimmer.duration = 0.07
            shimmer.autoreverses = true
            shimmer.repeatCount = .infinity
            s.lens.add(shimmer, forKey: "shimmer")

            let label = CAKeyframeAnimation(keyPath: "foregroundColor")
            label.values = [lit, lit, rest, rest]
            label.keyTimes = [0, 0.28, 0.42, 1]
            add(label, to: s.label, begin: begin, fill: .removed)
        }
    }

    private func add(_ animation: CAKeyframeAnimation, to layer: CALayer, begin: CFTimeInterval, fill: CAMediaTimingFillMode) {
        animation.duration = period
        animation.beginTime = begin
        animation.repeatCount = .infinity
        animation.fillMode = fill
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "pluck")
    }
}
