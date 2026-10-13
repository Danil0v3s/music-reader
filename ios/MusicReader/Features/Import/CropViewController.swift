import UIKit

/// Frames one piece on a photographed page before it goes to recognition. Audiveris reads a tight crop of a
/// single tune far better than a whole page with background, neighbouring pieces and the page's curve.
/// Drag the corners or the edges; drag inside the frame to move it.
final class CropViewController: UIViewController {
    private let image: UIImage
    private let onDone: (UIImage) -> Void
    private let imageView = UIImageView()
    private let frameView = CropFrameView()
    private let dim = CAShapeLayer()
    /// The crop in image pixel coordinates.
    private var crop: CGRect
    private var dragStart: (point: CGPoint, crop: CGRect, handle: CropFrameView.Handle)?

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        self.image = image.normalisedOrientation()
        self.onDone = onDone
        let size = self.image.size
        // Start a little inside the edges, which is where the page usually is.
        self.crop = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.05, dy: size.height * 0.05)
        super.init(nibName: nil, bundle: nil)
        title = "Frame the Music"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let read = UIBarButtonItem(title: "Read", primaryAction: UIAction { [weak self] _ in self?.finish() })
        read.style = .prominent
        navigationItem.rightBarButtonItem = read
        navigationItem.rightBarButtonItems = [read, UIBarButtonItem(title: "Whole Image", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.crop = CGRect(origin: .zero, size: self.image.size)
            self.layoutFrame()
        })]

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        view.layer.addSublayer(dim)
        view.addSubview(frameView)

        let hint = UILabel()
        hint.text = "Fit the frame around one piece: title to final barline."
        hint.textColor = .white.withAlphaComponent(0.8)
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        view.addSubview(hint)
        [imageView, hint].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -12),
            hint.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutFrame()
    }

    /// Where the image is drawn inside the aspect-fit image view, in view coordinates.
    private var imageRect: CGRect {
        let bounds = imageView.frame
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var scale: CGFloat { imageRect.width / image.size.width }

    private func toView(_ r: CGRect) -> CGRect {
        let ir = imageRect, s = scale
        return CGRect(x: ir.minX + r.minX * s, y: ir.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    private func layoutFrame() {
        let r = toView(crop)
        frameView.frame = r.insetBy(dx: -CropFrameView.touchSlop, dy: -CropFrameView.touchSlop)
        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(rect: r))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.path = path.cgPath
        CATransaction.commit()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: view)
        switch g.state {
        case .began:
            let handle = frameView.handle(at: view.convert(p, to: frameView))
            dragStart = handle.map { (p, crop, $0) }
        case .changed:
            guard let start = dragStart else { return }
            let d = CGPoint(x: (p.x - start.point.x) / scale, y: (p.y - start.point.y) / scale)
            crop = adjusted(start.crop, by: d, handle: start.handle)
            layoutFrame()
        default:
            dragStart = nil
        }
    }

    private func adjusted(_ r: CGRect, by d: CGPoint, handle: CropFrameView.Handle) -> CGRect {
        let bounds = CGRect(origin: .zero, size: image.size)
        let minSide = min(image.size.width, image.size.height) * 0.08
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .move:
            let dx = max(-r.minX, min(bounds.maxX - r.maxX, d.x)), dy = max(-r.minY, min(bounds.maxY - r.maxY, d.y))
            return r.offsetBy(dx: dx, dy: dy)
        case .edges(let left, let top, let right, let bottom):
            if left { minX = max(0, min(maxX - minSide, minX + d.x)) }
            if right { maxX = min(bounds.maxX, max(minX + minSide, maxX + d.x)) }
            if top { minY = max(0, min(maxY - minSide, minY + d.y)) }
            if bottom { maxY = min(bounds.maxY, max(minY + minSide, maxY + d.y)) }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func finish() {
        let pixelScale = image.scale
        let px = CGRect(x: crop.minX * pixelScale, y: crop.minY * pixelScale, width: crop.width * pixelScale, height: crop.height * pixelScale).integral
        guard let cg = image.cgImage?.cropping(to: px) else { return }
        onDone(UIImage(cgImage: cg))
    }
}

/// The crop frame: a border with corner marks. Touches near a corner or edge resize; inside moves.
final class CropFrameView: UIView {
    enum Handle { case move, edges(left: Bool, top: Bool, right: Bool, bottom: Bool) }
    static let touchSlop: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    func handle(at p: CGPoint) -> Handle? {
        let inner = bounds.insetBy(dx: Self.touchSlop, dy: Self.touchSlop)
        guard bounds.insetBy(dx: -8, dy: -8).contains(p) else { return nil }
        let slop = Self.touchSlop * 1.5
        let left = abs(p.x - inner.minX) < slop, right = abs(p.x - inner.maxX) < slop
        let top = abs(p.y - inner.minY) < slop, bottom = abs(p.y - inner.maxY) < slop
        if left || right || top || bottom { return .edges(left: left, top: top, right: right, bottom: bottom) }
        return inner.contains(p) ? .move : nil
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = bounds.insetBy(dx: Self.touchSlop, dy: Self.touchSlop)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r)
        // Corner marks.
        ctx.setLineWidth(5)
        let l: CGFloat = 22
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: x + dx * l, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + dy * l))
        }
        ctx.strokePath()
        // Thirds, faint, to help line up staves.
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: r.minX, y: y))
            ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()
    }
}

extension UIImage {
    /// Redraws the image so its pixels are upright (photos carry an EXIF orientation instead).
    func normalisedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
