import Foundation

/// SMuFL code points used from Bravura (Standard Music Font Layout, w3c.github.io/smufl). A SMuFL font's
/// em is 4 staff spaces, so drawing at `4 × staffSpace` points makes every glyph engraving-size, and each
/// glyph's origin sits on the staff position it denotes.
public enum SMuFL {
    public static let gClef: Character = "\u{E050}"
    public static let cClef: Character = "\u{E05C}"
    public static let fClef: Character = "\u{E062}"
    public static let gClef8vb: Character = "\u{E052}"

    public static let noteheadDoubleWhole: Character = "\u{E0A0}"
    public static let noteheadWhole: Character = "\u{E0A2}"
    public static let noteheadHalf: Character = "\u{E0A3}"
    public static let noteheadBlack: Character = "\u{E0A4}"
    public static let noteheadDiamondWhite: Character = "\u{E0D9}"

    public static func timeSigDigit(_ d: Int) -> Character { Character(UnicodeScalar(0xE080 + d)!) }
    public static let timeSigCommon: Character = "\u{E08A}"
    public static let timeSigCut: Character = "\u{E08B}"

    public static let flat: Character = "\u{E260}"
    public static let natural: Character = "\u{E261}"
    public static let sharp: Character = "\u{E262}"
    public static let doubleSharp: Character = "\u{E263}"
    public static let doubleFlat: Character = "\u{E264}"

    public static let augmentationDot: Character = "\u{E1E7}"
    public static let repeatDots: Character = "\u{E043}"

    public static let fermataAbove: Character = "\u{E4C0}"
    public static let fermataBelow: Character = "\u{E4C1}"

    public static let downBow: Character = "\u{E610}"
    public static let upBow: Character = "\u{E612}"
    public static let thumbPosition: Character = "\u{E624}"
    public static let harmonic: Character = "\u{E614}"

    public static let metNoteHalfUp: Character = "\u{E1D3}"
    public static let metNoteQuarterUp: Character = "\u{E1D5}"
    public static let metNote8thUp: Character = "\u{E1D7}"
    public static let metAugmentationDot: Character = "\u{E1E7}"

    public static func accidental(_ a: Accidental) -> Character {
        switch a {
        case .doubleFlat: doubleFlat
        case .flat: flat
        case .natural: natural
        case .sharp: sharp
        case .doubleSharp: doubleSharp
        }
    }

    /// Width in staff spaces (from Bravura's metadata), for spacing.
    public static func accidentalWidth(_ a: Accidental) -> Double {
        switch a {
        case .doubleFlat: 1.64
        case .flat: 0.9
        case .natural: 0.67
        case .sharp: 1.0
        case .doubleSharp: 1.0
        }
    }

    public static func notehead(_ kind: NoteValue.Kind, harmonic: Bool = false) -> Character {
        if harmonic { return noteheadDiamondWhite }
        switch kind {
        case .breve: return noteheadDoubleWhole
        case .whole: return noteheadWhole
        case .half: return noteheadHalf
        default: return noteheadBlack
        }
    }

    /// Notehead width in staff spaces.
    public static func noteheadWidth(_ kind: NoteValue.Kind) -> Double {
        switch kind {
        case .breve: 2.5
        case .whole: 1.69
        default: 1.18
        }
    }

    public static func rest(_ kind: NoteValue.Kind) -> Character {
        switch kind {
        case .breve: "\u{E4E2}"
        case .whole: "\u{E4E3}"
        case .half: "\u{E4E4}"
        case .quarter: "\u{E4E5}"
        case .eighth: "\u{E4E6}"
        case .sixteenth: "\u{E4E7}"
        case .thirtySecond: "\u{E4E8}"
        case .sixtyFourth: "\u{E4E9}"
        }
    }

    public static func flag(beams: Int, up: Bool) -> Character? {
        guard beams > 0 else { return nil }
        return Character(UnicodeScalar(0xE240 + (min(beams, 4) - 1) * 2 + (up ? 0 : 1))!)
    }

    public static func articulation(_ a: Articulation, above: Bool) -> Character? {
        let base: Int? = switch a {
        case .accent: 0xE4A0
        case .staccato: 0xE4A2
        case .tenuto: 0xE4A4
        case .staccatissimo: 0xE4A6
        case .spiccato: 0xE4A6
        case .marcato: 0xE4AC
        case .fermata: nil
        }
        return base.map { Character(UnicodeScalar($0 + (above ? 0 : 1))!) }
    }

    /// Dynamics are spelled from SMuFL's letter glyphs (p m f r s z).
    public static func dynamic(_ d: Dynamic) -> String {
        let letters: [Character: Character] = ["p": "\u{E520}", "m": "\u{E521}", "f": "\u{E522}", "r": "\u{E523}", "s": "\u{E524}", "z": "\u{E525}"]
        return String(d.rawValue.compactMap { letters[$0] })
    }
}
