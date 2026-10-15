import ScoreKit
import UIKit

/// Colours and type. The score is ink on warm paper (light) or light ink on near-black (dark). The accent
/// is a rosin amber; intonation uses the conventional green / amber / red.
enum Theme {
    static let paper = UIColor(named: "Paper")!
    static let ink = UIColor(named: "Ink")!
    static let inkSoft = UIColor(named: "InkSoft")!
    static let chrome = UIColor(named: "Chrome")!
    static let accent = UIColor(named: "AccentColor")!

    static let inTune = UIColor.systemGreen
    static let close = UIColor.systemOrange
    static let off = UIColor.systemRed
    static let playing = UIColor.systemBlue

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
