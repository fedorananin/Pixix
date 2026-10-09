import Foundation
import PixixCodec

/// A way of writing a color down.
public enum ColorNotation: String, CaseIterable, Codable, Sendable, Identifiable {
    case hex, rgb
    /// The channels as fractions of one, the way Swift, Core Graphics and shaders take them.
    case unit
    case hsl, hsb
    /// Lightness, chroma and hue in OKLab, as newer style sheets write colors.
    case oklch

    public var id: String { rawValue }

    /// A short label, for a narrow column beside the value.
    public var title: String {
        switch self {
        case .unit: "0–1"
        default: rawValue.uppercased()
        }
    }

    /// What the notation is called where there is room to say it.
    public var name: String {
        switch self {
        case .unit: "RGB 0–1"
        default: title
        }
    }

    /// The numbers alone, for showing beside the name of the notation: "#1A2B3C", "26, 43, 60",
    /// "210°, 40%, 17%". `bareHex` leaves the # out, for a field that has one already.
    public func value(of color: RGBAColor, bareHex: Bool = false) -> String {
        switch self {
        case .hex:
            let (red, green, blue) = color.bytes
            return String(format: bareHex ? "%02X%02X%02X" : "#%02X%02X%02X", red, green, blue)
        case .rgb:
            let (red, green, blue) = color.bytes
            return "\(red), \(green), \(blue)"
        case .unit:
            let (red, green, blue) = color.bytes
            return [red, green, blue].map { String(format: "%.3f", Double($0) / 255) }.joined(separator: ", ")
        case .hsl:
            let (hue, saturation, lightness) = color.hsl
            return "\(hue)°, \(saturation)%, \(lightness)%"
        case .hsb:
            let (hue, saturation, brightness) = color.hsb
            return "\(hue)°, \(saturation)%, \(brightness)%"
        case .oklch:
            let (lightness, chroma, hue) = color.oklch
            return "\(Self.short(lightness * 100, places: 1))% \(Self.short(chroma, places: 3)) \(Self.short(hue, places: 1))"
        }
    }

    /// The color as a style sheet or a design tool takes it: "#1A2B3C", "rgb(26, 43, 60)", "hsl(210, 40%, 17%)",
    /// "oklch(28.3% 0.039 249.3)". The fractions of one are left bare, for whatever call they are pasted into.
    public func text(of color: RGBAColor, bareHex: Bool = false) -> String {
        switch self {
        case .hex, .unit:
            return value(of: color, bareHex: bareHex)
        case .rgb:
            return "rgb(\(value(of: color)))"
        case .hsl:
            let (hue, saturation, lightness) = color.hsl
            return "hsl(\(hue), \(saturation)%, \(lightness)%)"
        case .hsb:
            let (hue, saturation, brightness) = color.hsb
            return "hsb(\(hue), \(saturation)%, \(brightness)%)"
        case .oklch:
            return "oklch(\(value(of: color)))"
        }
    }

    /// A number with no more decimals than it needs: 62.8, 100, 0.
    private static func short(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

public extension RGBAColor {
    /// The channels as whole numbers from 0 to 255. Every notation is counted from these, so that they all
    /// name the same color.
    var bytes: (red: Int, green: Int, blue: Int) {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(red), byte(green), byte(blue))
    }

    /// Hue in degrees, saturation and lightness in percent.
    var hsl: (hue: Int, saturation: Int, lightness: Int) {
        let (hue, high, low) = hueAndRange
        let lightness = (high + low) / 2
        let spread = high - low
        let saturation = spread == 0 ? 0 : spread / (1 - abs(2 * lightness - 1))
        return (hue, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    /// Hue in degrees, saturation and brightness in percent.
    var hsb: (hue: Int, saturation: Int, brightness: Int) {
        let (hue, high, low) = hueAndRange
        let saturation = high == 0 ? 0 : (high - low) / high
        return (hue, Int((saturation * 100).rounded()), Int((high * 100).rounded()))
    }

    /// Lightness as 0...1, chroma, and hue in degrees, in OKLab (Björn Ottosson, 2020). A gray has no hue,
    /// and gets 0 for it.
    var oklch: (lightness: Double, chroma: Double, hue: Double) {
        func linear(_ byte: Int) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (linear(bytes.red), linear(bytes.green), linear(bytes.blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let yellow = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = (a * a + yellow * yellow).squareRoot()
        // Below what three decimals can show, the hue is noise.
        guard chroma >= 0.0005 else { return (lightness, 0, 0) }
        var hue = atan2(yellow, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (lightness, chroma, hue)
    }

    /// The hue in whole degrees, and the strongest and the weakest channel as 0...1.
    private var hueAndRange: (hue: Int, high: Double, low: Double) {
        let (r, g, b) = (Double(bytes.red) / 255, Double(bytes.green) / 255, Double(bytes.blue) / 255)
        let high = max(r, g, b), low = min(r, g, b)
        let spread = high - low
        guard spread > 0 else { return (0, high, low) }
        var sixth: Double
        if high == r {
            sixth = ((g - b) / spread).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            sixth = (b - r) / spread + 2
        } else {
            sixth = (r - g) / spread + 4
        }
        if sixth < 0 { sixth += 6 }
        // 359.6° is written as 0°, not as 360°.
        return (Int((sixth * 60).rounded()) % 360, high, low)
    }
}
