import ScoreKit
import UIKit

/// Colours and type: "Varnish & Ink", the light cut. Soft ink on warm paper (light) or light ink on warm
/// near-black (dark), white floating surfaces with hairlines and soft shadows. Varnish (the accent) is for
/// actions and what's playing; rosin is for things that move (playheads, loops); intonation uses the
/// conventional green / amber / red.
enum Theme {
    static let paper = UIColor(named: "Paper")!
    static let ink = UIColor(named: "Ink")!
    static let inkSoft = UIColor(named: "InkSoft")!
    static let chrome = UIColor(named: "Chrome")!
    static let accent = UIColor(named: "AccentColor")!
    /// Highlights that move: the playhead, the loop, the selected tab.
    static let rosin = UIColor(named: "Rosin")!
    /// The pale rosin chip behind a loop, and the text on it.
    static let rosinSoft = UIColor(named: "RosinSoft")!
    static let rosinInk = UIColor(named: "RosinInk")!
    /// Floating cards and bars (white on paper).
    static let surface = UIColor(named: "Surface")!
    /// The selected row or tab: a pale varnish wash.
    static let selected = UIColor(named: "Selected")!
    /// Hairline borders on surfaces.
    static var hairline: UIColor { ink.withAlphaComponent(0.12) }

    static let inTune = UIColor.systemGreen
    static let close = UIColor.systemOrange
    static let off = UIColor.systemRed
    static var playing: UIColor { accent }

    static func color(for rating: NoteIntonation.Rating) -> UIColor {
        switch rating {
        case .inTune: inTune
        case .close: close
        case .off, .wrongNote: off
        case .missed: inkSoft
        }
    }

    static let gutter: CGFloat = 16
    static let radius: CGFloat = 14
}

enum Fonts {
    /// Fraunces (display): screen titles, score titles, note names. SemiBold by default; `.bold` or `.black` to shout.
    static func display(_ size: CGFloat, weight: UIFont.Weight = .semibold, relativeTo style: UIFont.TextStyle? = nil) -> UIFont {
        let name = weight >= .heavy ? "Fraunces144pt-Black" : weight >= .bold ? "Fraunces144pt-Bold" : "Fraunces144pt-SemiBold"
        let font = UIFont(name: name, size: size) ?? serif(size, weight: .semibold)
        return style.map { UIFontMetrics(forTextStyle: $0).scaledFont(for: font) } ?? font
    }

    /// Instrument Sans: the interface's own text (buttons, rows, captions), scaled with Dynamic Type.
    static func ui(_ size: CGFloat, weight: UIFont.Weight = .regular, relativeTo style: UIFont.TextStyle = .body) -> UIFont {
        let name = weight >= .bold ? "InstrumentSans-Bold" : weight >= .semibold ? "InstrumentSans-SemiBold"
            : weight >= .medium ? "InstrumentSans-Medium" : "InstrumentSans-Regular"
        let font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    /// JetBrains Mono: small capitals labels, tempo, codes, cents.
    static func label(_ size: CGFloat, weight: UIFont.Weight = .medium) -> UIFont {
        UIFont(name: weight >= .bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Medium", size: size) ?? mono(size, weight: weight)
    }

    /// The SMuFL music font. Its em is four staff spaces.
    static func bravura(_ size: CGFloat) -> UIFont {
        UIFont(name: "Bravura", size: size) ?? .systemFont(ofSize: size)
    }

    /// Engraved-looking text in the score (titles, tempo words, expression text).
    static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
        if italic { descriptor = descriptor.withSymbolicTraits(.traitItalic) ?? descriptor }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func rounded(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size)
    }

    static func mono(_ size: CGFloat, weight: UIFont.Weight = .medium) -> UIFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// A small-capitals label in the mono face, letter-spaced (COLLECTIONS, OR WITH EMAIL).
    static func labelText(_ text: String, size: CGFloat = 11, color: UIColor = Theme.inkSoft) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [.font: label(size), .kern: 1.5, .foregroundColor: color])
    }
}

extension NoteValue.Kind {
    /// A music-font glyph for palette buttons (an up-stem note).
    var paletteGlyph: String {
        switch self {
        case .breve: "\u{E1D0}"
        case .whole: "\u{E1D2}"
        case .half: "\u{E1D3}"
        case .quarter: "\u{E1D5}"
        case .eighth: "\u{E1D7}"
        case .sixteenth: "\u{E1D9}"
        case .thirtySecond: "\u{E1DB}"
        case .sixtyFourth: "\u{E1DD}"
        }
    }
}

extension NSLayoutConstraint {
    /// Keeps `view` centred in `guide`, as wide as the guide allows (less `inset` each side) up to `maxWidth`:
    /// full width on a phone, a comfortable column on an iPad.
    static func readable(_ view: UIView, in guide: UILayoutGuide, maxWidth: CGFloat, inset: CGFloat) -> [NSLayoutConstraint] {
        let fill = view.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -2 * inset)
        fill.priority = .defaultHigh
        return [
            view.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: inset),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            fill,
        ]
    }
}

enum Device {
    /// "iPad" or "iPhone", for text that talks about this device.
    @MainActor static var name: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    @MainActor static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

extension UICollectionViewListCell {
    /// Library rows: white on paper, a pale varnish wash while selected or pressed.
    func applySurfaceBackground() {
        configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listCell().updated(for: state)
            background.backgroundColor = state.isSelected || state.isHighlighted ? Theme.selected : Theme.surface
            cell.backgroundConfiguration = background
        }
    }
}
