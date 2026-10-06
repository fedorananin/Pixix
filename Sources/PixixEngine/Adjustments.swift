import CoreImage
import Foundation

/// Slider-style corrections that stay editable on a layer. Every value is 0 when neutral.
public struct Adjustments: Codable, Sendable, Hashable {
    /// -1...1
    public var brightness = 0.0
    /// -1...1, two stops either way.
    public var exposure = 0.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var saturation = 0.0
    public var vibrance = 0.0
    /// -1 cool ... 1 warm
    public var temperature = 0.0
    /// -1 green ... 1 magenta
    public var tint = 0.0
    /// 0...1
    public var sharpness = 0.0
    /// 0...1
    public var vignette = 0.0

    public init() {}

    public var isNeutral: Bool { self == Adjustments() }

    /// Applies the corrections. `extent` is the area the result is cropped to.
    public func apply(to image: CIImage, extent: CGRect) -> CIImage {
        guard !isNeutral else { return image }
        var result = image
        if exposure != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure * 2])
        }
        if brightness != 0 || contrast != 0 || saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness * 0.35,
                kCIInputContrastKey: 1 + contrast * 0.5,
                kCIInputSaturationKey: 1 + saturation,
            ])
        }
        if highlights != 0 || shadows != 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + highlights * 0.7,
                "inputShadowAmount": shadows,
            ])
        }
        if vibrance != 0 {
            result = result.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: vibrance])
        }
        if temperature != 0 || tint != 0 {
            // A lower target temperature renders the picture warmer.
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - temperature * 2500, y: tint * 100),
            ])
        }
        if sharpness > 0 {
            result = result.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: sharpness * 2, kCIInputRadiusKey: 1.7,
            ])
        }
        if vignette > 0 {
            result = result.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: vignette * 2, kCIInputRadiusKey: 1 + vignette,
            ])
        }
        return result.cropped(to: extent)
    }
}

/// One-click looks, stored on a layer next to its adjustments.
public enum PhotoFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, vivid, warm, cool, fade, chrome, instant, process, transfer, sepia, mono, tonal, noir

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Original"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .fade: "Fade"
        case .chrome: "Chrome"
        case .instant: "Instant"
        case .process: "Process"
        case .transfer: "Transfer"
        case .sepia: "Sepia"
        case .mono: "Mono"
        case .tonal: "Tonal"
        case .noir: "Noir"
        }
    }

    public func apply(to image: CIImage, extent: CGRect) -> CIImage {
        let result: CIImage
        switch self {
        case .none:
            return image
        case .vivid:
            result = image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.08])
                .applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.4])
        case .warm:
            result = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5000, y: 0),
            ])
        case .cool:
            result = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8500, y: 0),
            ])
        case .fade: result = image.applyingFilter("CIPhotoEffectFade")
        case .chrome: result = image.applyingFilter("CIPhotoEffectChrome")
        case .instant: result = image.applyingFilter("CIPhotoEffectInstant")
        case .process: result = image.applyingFilter("CIPhotoEffectProcess")
        case .transfer: result = image.applyingFilter("CIPhotoEffectTransfer")
        case .sepia: result = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
        case .mono: result = image.applyingFilter("CIPhotoEffectMono")
        case .tonal: result = image.applyingFilter("CIPhotoEffectTonal")
        case .noir: result = image.applyingFilter("CIPhotoEffectNoir")
        }
        return result.cropped(to: extent)
    }
}
