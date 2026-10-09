import Foundation
import PixixCodec

/// A way of writing a color down.
public enum ColorNotation: String, CaseIterable, Codable, Sendable, Identifiable {
    case hex, rgb, hsl, hsb

    public var id: String { rawValue }

    public var title: String { rawValue.uppercased() }

    /// The numbers alone, for showing beside the name of the notation: "#1A2B3C", "26, 43, 60", "210°, 40%, 17%".
    public func value(of color: RGBAColor) -> String {
        switch self {
        case .hex:
            let (red, green, blue) = color.bytes
            return String(format: "#%02X%02X%02X", red, green, blue)
        case .rgb:
            let (red, green, blue) = color.bytes
            return "\(red), \(green), \(blue)"
        case .hsl:
            let (hue, saturation, lightness) = color.hsl
            return "\(hue)°, \(saturation)%, \(lightness)%"
        case .hsb:
            let (hue, saturation, brightness) = color.hsb
            return "\(hue)°, \(saturation)%, \(brightness)%"
        }
    }

    /// The color as a style sheet or a design tool takes it: "#1A2B3C", "rgb(26, 43, 60)", "hsl(210, 40%, 17%)".
    public func text(of color: RGBAColor) -> String {
        switch self {
        case .hex:
            return value(of: color)
        case .rgb:
            return "rgb(\(value(of: color)))"
        case .hsl:
            let (hue, saturation, lightness) = color.hsl
            return "hsl(\(hue), \(saturation)%, \(lightness)%)"
        case .hsb:
            let (hue, saturation, brightness) = color.hsb
            return "hsb(\(hue), \(saturation)%, \(brightness)%)"
        }
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
