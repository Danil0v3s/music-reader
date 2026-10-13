import Foundation

/// An exact rational number, used for every musical time value so tuplets and dotted notes add up with
/// no floating-point drift. Durations are fractions of a whole note: a quarter is 1/4, a dotted eighth 3/16,
/// a triplet eighth 1/12.
public struct Fraction: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let num: Int
    public let den: Int

    public init(_ num: Int, _ den: Int = 1) {
        precondition(den != 0, "Fraction with a zero denominator")
        let sign = den < 0 ? -1 : 1
        let g = Fraction.gcd(abs(num), abs(den))
        self.num = sign * num / max(g, 1)
        self.den = sign * den / max(g, 1)
    }

    public static let zero = Fraction(0)
    public static let one = Fraction(1)

    public var double: Double { Double(num) / Double(den) }
    public var isZero: Bool { num == 0 }
    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }

    public static func + (a: Fraction, b: Fraction) -> Fraction { Fraction(a.num * b.den + b.num * a.den, a.den * b.den) }
    public static func - (a: Fraction, b: Fraction) -> Fraction { Fraction(a.num * b.den - b.num * a.den, a.den * b.den) }
    public static func * (a: Fraction, b: Fraction) -> Fraction { Fraction(a.num * b.num, a.den * b.den) }
    public static func / (a: Fraction, b: Fraction) -> Fraction { Fraction(a.num * b.den, a.den * b.num) }
    public static func * (a: Fraction, k: Int) -> Fraction { Fraction(a.num * k, a.den) }
    public static func += (a: inout Fraction, b: Fraction) { a = a + b }
    public static func -= (a: inout Fraction, b: Fraction) { a = a - b }
    public static func < (a: Fraction, b: Fraction) -> Bool { a.num * b.den < b.num * a.den }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    static func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }

    // Encoded as "3/16" so stored scores stay readable.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        let parts = s.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 1 || (parts.count == 2 && parts[1] != 0) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad fraction \(s)"))
        }
        self.init(parts[0], parts.count == 2 ? parts[1] : 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
