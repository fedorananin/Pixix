import CoreImage
import Foundation

/// One slider of an effect dialog.
public struct EffectParameter: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var range: ClosedRange<Double>
    public var defaultValue: Double
    public var step: Double

    public init(_ id: String, _ name: String, _ range: ClosedRange<Double>, _ defaultValue: Double, step: Double = 0) {
        self.id = id
        self.name = name
        self.range = range
        self.defaultValue = defaultValue
        self.step = step
    }
}

/// A destructive filter from the Adjustments or Effects menu.
public struct EffectDescriptor: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// "Adjustments", or the Effects submenu the item lives in.
    public var category: String
    public var parameters: [EffectParameter]
    let build: @Sendable (CIImage, [String: Double], CGRect) -> CIImage

    public var defaults: [String: Double] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) })
    }

    /// Runs the effect. The result covers exactly `extent`.
    public func apply(to image: CIImage, values: [String: Double], extent: CGRect) -> CIImage {
        var merged = defaults
        for (key, value) in values { merged[key] = value }
        return build(image, merged, extent).cropped(to: extent)
    }
}

public enum EffectCatalog {
    public static let adjustmentsCategory = "Adjustments"

    public static func find(_ id: String) -> EffectDescriptor? { all.first { $0.id == id } }

    public static var adjustments: [EffectDescriptor] { all.filter { $0.category == adjustmentsCategory } }

    /// Effects grouped by submenu, in menu order.
    public static var effectGroups: [(category: String, effects: [EffectDescriptor])] {
        var order: [String] = []
        var groups: [String: [EffectDescriptor]] = [:]
        for effect in all where effect.category != adjustmentsCategory {
            if groups[effect.category] == nil { order.append(effect.category) }
            groups[effect.category, default: []].append(effect)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private typealias P = EffectParameter

    private static func adjustment(
        _ id: String, _ name: String, _ parameters: [P] = [],
        _ build: @escaping @Sendable (CIImage, [String: Double], CGRect) -> CIImage
    ) -> EffectDescriptor {
        EffectDescriptor(id: id, name: name, category: adjustmentsCategory, parameters: parameters, build: build)
    }

    private static func effect(
        _ category: String, _ id: String, _ name: String, _ parameters: [P] = [],
        _ build: @escaping @Sendable (CIImage, [String: Double], CGRect) -> CIImage
    ) -> EffectDescriptor {
        EffectDescriptor(id: id, name: name, category: category, parameters: parameters, build: build)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// A point inside the extent given as fractions of its size, in Core Image coordinates.
    private static func point(_ extent: CGRect, _ x: Double, _ y: Double) -> CIVector {
        CIVector(x: extent.minX + extent.width * x, y: extent.minY + extent.height * (1 - y))
    }

    private static let centerParameters = [P("cx", "Center X", 0...1, 0.5), P("cy", "Center Y", 0...1, 0.5)]

    public static let all: [EffectDescriptor] = [
        // MARK: Adjustments
        adjustment("auto", "Auto Enhance") { image, _, _ in
            image.autoAdjustmentFilters(options: [.redEye: false, .crop: false, .level: false])
                .reduce(image) { result, filter in
                    filter.setValue(result, forKey: kCIInputImageKey)
                    return filter.outputImage ?? result
                }
        },
        adjustment("brightnessContrast", "Brightness / Contrast", [
            P("brightness", "Brightness", -100...100, 0), P("contrast", "Contrast", -100...100, 0),
        ]) { image, v, _ in
            image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: v["brightness"]! / 250, kCIInputContrastKey: 1 + v["contrast"]! / 150,
            ])
        },
        adjustment("hueSaturation", "Hue / Saturation", [
            P("hue", "Hue", -180...180, 0), P("saturation", "Saturation", 0...200, 100),
            P("lightness", "Lightness", -100...100, 0),
        ]) { image, v, _ in
            image
                .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: radians(v["hue"]!)])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: v["saturation"]! / 100, kCIInputBrightnessKey: v["lightness"]! / 250,
                ])
        },
        adjustment("exposure", "Exposure", [P("ev", "Stops", -3...3, 0)]) { image, v, _ in
            image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v["ev"]!])
        },
        adjustment("levels", "Levels", [
            P("black", "Black Point", 0...254, 0, step: 1), P("white", "White Point", 1...255, 255, step: 1),
            P("gamma", "Gamma", 0.1...3, 1),
        ]) { image, v, _ in
            let black = v["black"]! / 255
            let white = max(v["white"]! / 255, black + 1 / 255)
            let scale = 1 / (white - black)
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                    "inputBiasVector": CIVector(x: -black * scale, y: -black * scale, z: -black * scale, w: 0),
                ])
                .applyingFilter("CIColorClamp")
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / max(v["gamma"]!, 0.01)])
        },
        adjustment("curves", "Curves", [
            P("p0", "Blacks", 0...1, 0), P("p1", "Shadows", 0...1, 0.25), P("p2", "Midtones", 0...1, 0.5),
            P("p3", "Highlights", 0...1, 0.75), P("p4", "Whites", 0...1, 1),
        ]) { image, v, _ in
            image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: v["p0"]!), "inputPoint1": CIVector(x: 0.25, y: v["p1"]!),
                "inputPoint2": CIVector(x: 0.5, y: v["p2"]!), "inputPoint3": CIVector(x: 0.75, y: v["p3"]!),
                "inputPoint4": CIVector(x: 1, y: v["p4"]!),
            ])
        },
        adjustment("temperature", "Temperature / Tint", [
            P("temperature", "Temperature", -100...100, 0), P("tint", "Tint", -100...100, 0),
        ]) { image, v, _ in
            image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - v["temperature"]! * 30, y: v["tint"]!),
            ])
        },
        adjustment("vibrance", "Vibrance", [P("amount", "Amount", -100...100, 30)]) { image, v, _ in
            image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: v["amount"]! / 100])
        },
        adjustment("invert", "Invert Colors") { image, _, _ in image.applyingFilter("CIColorInvert") },
        adjustment("blackAndWhite", "Black and White") { image, _, _ in
            image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        },
        adjustment("sepia", "Sepia", [P("intensity", "Intensity", 0...100, 80)]) { image, v, _ in
            image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: v["intensity"]! / 100])
        },
        adjustment("posterize", "Posterize", [P("levels", "Levels", 2...32, 6, step: 1)]) { image, v, _ in
            image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": v["levels"]!])
        },
        adjustment("threshold", "Threshold", [P("threshold", "Threshold", 0...100, 50)]) { image, v, _ in
            image.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": v["threshold"]! / 100])
        },

        // MARK: Blurs
        effect("Blurs", "gaussianBlur", "Gaussian Blur", [P("radius", "Radius", 0...100, 8)]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v["radius"]!])
        },
        effect("Blurs", "motionBlur", "Motion Blur", [
            P("radius", "Distance", 0...200, 20), P("angle", "Angle", -180...180, 0),
        ]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: v["radius"]!, kCIInputAngleKey: radians(v["angle"]!),
            ])
        },
        effect("Blurs", "zoomBlur", "Zoom Blur", [P("amount", "Amount", 0...100, 15)] + centerParameters) { image, v, extent in
            image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputAmountKey: v["amount"]!, kCIInputCenterKey: point(extent, v["cx"]!, v["cy"]!),
            ])
        },
        effect("Blurs", "boxBlur", "Box Blur", [P("radius", "Radius", 1...100, 10)]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: v["radius"]!])
        },
        effect("Blurs", "unfocus", "Unfocus", [P("radius", "Radius", 1...100, 8)]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: v["radius"]!])
        },

        // MARK: Sharpen and noise
        effect("Photo", "sharpen", "Sharpen", [P("amount", "Amount", 0...100, 40)]) { image, v, _ in
            image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: v["amount"]! / 40, kCIInputRadiusKey: 1.7,
            ])
        },
        effect("Photo", "unsharpMask", "Unsharp Mask", [
            P("radius", "Radius", 0...50, 2.5), P("intensity", "Amount", 0...300, 80),
        ]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: v["radius"]!, kCIInputIntensityKey: v["intensity"]! / 100,
            ])
        },
        effect("Photo", "glow", "Glow", [P("radius", "Radius", 0...100, 10), P("intensity", "Intensity", 0...100, 50)]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: v["radius"]!, kCIInputIntensityKey: v["intensity"]! / 100,
            ])
        },
        effect("Photo", "gloom", "Soften", [P("radius", "Radius", 0...100, 10), P("intensity", "Intensity", 0...100, 50)]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CIGloom", parameters: [
                kCIInputRadiusKey: v["radius"]!, kCIInputIntensityKey: v["intensity"]! / 100,
            ])
        },
        effect("Photo", "vignette", "Vignette", [
            P("intensity", "Intensity", 0...100, 50), P("radius", "Radius", 0...100, 60),
        ]) { image, v, _ in
            image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: v["intensity"]! / 50, kCIInputRadiusKey: v["radius"]! / 50,
            ])
        },
        effect("Noise", "addNoise", "Add Noise", [
            P("amount", "Amount", 0...100, 25), P("color", "Color Noise", 0...1, 0, step: 1),
        ]) { image, v, extent in
            guard var noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
            if v["color"]! < 0.5 {
                noise = noise.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            }
            let amount = v["amount"]! / 100
            // Center the noise on zero so it darkens as often as it brightens.
            let centered = noise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -amount / 2, y: -amount / 2, z: -amount / 2, w: 0),
            ]).cropped(to: extent)
            return centered
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
                .applyingFilter("CIColorClamp")
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        },
        effect("Noise", "reduceNoise", "Reduce Noise", [
            P("level", "Strength", 0...100, 30), P("sharpness", "Sharpness", 0...100, 40),
        ]) { image, v, _ in
            image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": v["level"]! / 1000, kCIInputSharpnessKey: v["sharpness"]! / 50,
            ])
        },
        effect("Noise", "median", "Median", []) { image, _, _ in
            image.clampedToExtent().applyingFilter("CIMedianFilter")
        },

        // MARK: Stylize
        effect("Stylize", "pixelate", "Pixelate", [P("scale", "Cell Size", 2...200, 12, step: 1)]) { image, v, extent in
            image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: v["scale"]!, kCIInputCenterKey: CIVector(x: extent.minX, y: extent.maxY),
            ])
        },
        effect("Stylize", "crystallize", "Crystallize", [P("radius", "Cell Size", 2...200, 20)]) { image, v, extent in
            image.clampedToExtent().applyingFilter("CICrystallize", parameters: [
                kCIInputRadiusKey: v["radius"]!, kCIInputCenterKey: point(extent, 0.5, 0.5),
            ])
        },
        effect("Stylize", "pointillize", "Pointillize", [P("radius", "Dot Size", 2...100, 12)]) { image, v, extent in
            image.clampedToExtent().applyingFilter("CIPointillize", parameters: [
                kCIInputRadiusKey: v["radius"]!, kCIInputCenterKey: point(extent, 0.5, 0.5),
            ])
        },
        effect("Stylize", "halftone", "Halftone", [
            P("width", "Dot Size", 2...60, 8), P("angle", "Angle", -90...90, 30),
        ]) { image, v, extent in
            image.clampedToExtent().applyingFilter("CIDotScreen", parameters: [
                kCIInputWidthKey: v["width"]!, kCIInputAngleKey: radians(v["angle"]!), kCIInputSharpnessKey: 0.7,
                kCIInputCenterKey: point(extent, 0.5, 0.5),
            ])
        },
        effect("Stylize", "emboss", "Emboss", [P("strength", "Strength", 0...4, 1)]) { image, v, _ in
            let k = v["strength"]!
            let weights: [CGFloat] = [-2 * k, -k, 0, -k, 1, k, 0, k, 2 * k]
            return image.clampedToExtent()
                .applyingFilter("CIConvolution3X3", parameters: [
                    "inputWeights": CIVector(values: weights, count: 9), "inputBias": 0,
                ])
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        },
        effect("Stylize", "edges", "Edge Detect", [P("intensity", "Intensity", 0...20, 4)]) { image, v, _ in
            image.clampedToExtent()
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: v["intensity"]!])
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        },
        effect("Stylize", "pencilSketch", "Pencil Sketch", [
            P("edge", "Edge Strength", 0.1...3, 1), P("threshold", "Threshold", 0...1, 0.1),
        ]) { image, v, _ in
            let lines = image.clampedToExtent().applyingFilter("CILineOverlay", parameters: [
                "inputEdgeIntensity": v["edge"]!, "inputThreshold": v["threshold"]!,
            ])
            // The filter outputs black lines on transparency; put paper under them.
            return lines.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 1, green: 1, blue: 1)),
            ]).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        },
        effect("Stylize", "comic", "Comic") { image, _, _ in
            image.clampedToExtent().applyingFilter("CIComicEffect")
        },
        effect("Stylize", "oilPaint", "Oil Painting", [P("radius", "Brush Size", 1...30, 6)]) { image, v, extent in
            // No built-in oil filter; a median pass followed by coarse posterized cells reads as brushwork.
            image.clampedToExtent()
                .applyingFilter("CIMedianFilter")
                .applyingFilter("CICrystallize", parameters: [
                    kCIInputRadiusKey: v["radius"]!, kCIInputCenterKey: point(extent, 0.5, 0.5),
                ])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v["radius"]! / 4])
        },

        // MARK: Distort
        effect("Distort", "twirl", "Twirl", [
            P("angle", "Angle", -720...720, 180), P("radius", "Radius", 0...100, 50),
        ] + centerParameters) { image, v, extent in
            image.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                kCIInputAngleKey: radians(v["angle"]!),
                kCIInputRadiusKey: min(extent.width, extent.height) * v["radius"]! / 100,
                kCIInputCenterKey: point(extent, v["cx"]!, v["cy"]!),
            ])
        },
        effect("Distort", "bulge", "Bulge", [
            P("scale", "Amount", -100...100, 50), P("radius", "Radius", 0...100, 50),
        ] + centerParameters) { image, v, extent in
            image.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputScaleKey: v["scale"]! / 100,
                kCIInputRadiusKey: min(extent.width, extent.height) * v["radius"]! / 100,
                kCIInputCenterKey: point(extent, v["cx"]!, v["cy"]!),
            ])
        },
        effect("Distort", "pinch", "Pinch", [
            P("scale", "Amount", 0...100, 50), P("radius", "Radius", 0...100, 50),
        ] + centerParameters) { image, v, extent in
            image.clampedToExtent().applyingFilter("CIPinchDistortion", parameters: [
                kCIInputScaleKey: v["scale"]! / 100,
                kCIInputRadiusKey: min(extent.width, extent.height) * v["radius"]! / 100,
                kCIInputCenterKey: point(extent, v["cx"]!, v["cy"]!),
            ])
        },
    ]
}
