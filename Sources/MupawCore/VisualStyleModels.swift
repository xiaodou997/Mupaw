import Foundation

public enum ScreenshotCanvasAspect: String, Codable, Sendable, CaseIterable, Hashable {
    case automatic
    case square
    case landscapeFourThree = "landscape_4_3"
    case landscapeSixteenNine = "landscape_16_9"
    case portraitThreeFour = "portrait_3_4"
    case portraitNineSixteen = "portrait_9_16"

    public var widthToHeightRatio: Double? {
        switch self {
        case .automatic:
            return nil
        case .square:
            return 1
        case .landscapeFourThree:
            return 4.0 / 3.0
        case .landscapeSixteenNine:
            return 16.0 / 9.0
        case .portraitThreeFour:
            return 3.0 / 4.0
        case .portraitNineSixteen:
            return 9.0 / 16.0
        }
    }
}

public enum ScreenshotBackgroundMode: String, Codable, Sendable, CaseIterable, Hashable {
    case solid
    case linearGradient = "linear_gradient"
}

public struct ScreenshotBackgroundStyle: Codable, Sendable, Equatable, Hashable {
    public var mode: ScreenshotBackgroundMode
    public var startColor: RGBAColor
    public var endColor: RGBAColor
    public var angleDegrees: Double

    public init(
        mode: ScreenshotBackgroundMode = .solid,
        startColor: RGBAColor,
        endColor: RGBAColor? = nil,
        angleDegrees: Double = 0
    ) {
        self.mode = mode
        self.startColor = startColor
        self.endColor = endColor ?? startColor
        self.angleDegrees = angleDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case startColor = "start_color"
        case endColor = "end_color"
        case angleDegrees = "angle_degrees"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(ScreenshotBackgroundMode.self, forKey: .mode) ?? .solid
        startColor = try container.decode(RGBAColor.self, forKey: .startColor)
        endColor = try container.decodeIfPresent(RGBAColor.self, forKey: .endColor) ?? startColor
        angleDegrees = try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 0
    }
}

public struct ScreenshotShadowStyle: Codable, Sendable, Equatable, Hashable {
    public var isEnabled: Bool
    public var color: RGBAColor
    public var blurRadius: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(
        isEnabled: Bool = true,
        color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.28),
        blurRadius: Double = 36,
        offsetX: Double = 0,
        offsetY: Double = 18
    ) {
        self.isEnabled = isEnabled
        self.color = color
        self.blurRadius = blurRadius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case color
        case blurRadius = "blur_radius"
        case offsetX = "offset_x"
        case offsetY = "offset_y"
    }
}

public struct ScreenshotVisualStyle: Codable, Sendable, Equatable, Hashable {
    public var background: ScreenshotBackgroundStyle
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: ScreenshotShadowStyle
    public var canvasAspect: ScreenshotCanvasAspect

    public init(
        background: ScreenshotBackgroundStyle,
        padding: Double = 96,
        cornerRadius: Double = 28,
        shadow: ScreenshotShadowStyle = ScreenshotShadowStyle(),
        canvasAspect: ScreenshotCanvasAspect = .automatic
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.canvasAspect = canvasAspect
    }

    private enum CodingKeys: String, CodingKey {
        case background
        case padding
        case cornerRadius = "corner_radius"
        case shadow
        case canvasAspect = "canvas_aspect"
    }
}

public enum ScreenshotStylePreset: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case cleanWhite = "clean_white"
    case softGray = "soft_gray"
    case ocean
    case sunset
    case midnight

    public var style: ScreenshotVisualStyle? {
        switch self {
        case .none:
            return nil
        case .cleanWhite:
            return ScreenshotVisualStyle(
                background: ScreenshotBackgroundStyle(
                    startColor: RGBAColor(red: 0.97, green: 0.97, blue: 0.98)
                ),
                padding: 88,
                cornerRadius: 26,
                shadow: ScreenshotShadowStyle(
                    color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.22),
                    blurRadius: 34,
                    offsetY: 16
                )
            )
        case .softGray:
            return ScreenshotVisualStyle(
                background: ScreenshotBackgroundStyle(
                    startColor: RGBAColor(red: 0.88, green: 0.90, blue: 0.93)
                ),
                padding: 96,
                cornerRadius: 30,
                shadow: ScreenshotShadowStyle(
                    color: RGBAColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.24),
                    blurRadius: 40,
                    offsetY: 18
                )
            )
        case .ocean:
            return ScreenshotVisualStyle(
                background: ScreenshotBackgroundStyle(
                    mode: .linearGradient,
                    startColor: RGBAColor(red: 0.18, green: 0.55, blue: 0.98),
                    endColor: RGBAColor(red: 0.12, green: 0.86, blue: 0.76),
                    angleDegrees: 28
                ),
                padding: 108,
                cornerRadius: 32,
                shadow: ScreenshotShadowStyle(
                    color: RGBAColor(red: 0.02, green: 0.15, blue: 0.28, alpha: 0.36),
                    blurRadius: 46,
                    offsetY: 20
                )
            )
        case .sunset:
            return ScreenshotVisualStyle(
                background: ScreenshotBackgroundStyle(
                    mode: .linearGradient,
                    startColor: RGBAColor(red: 0.98, green: 0.39, blue: 0.48),
                    endColor: RGBAColor(red: 0.99, green: 0.72, blue: 0.30),
                    angleDegrees: 22
                ),
                padding: 108,
                cornerRadius: 32,
                shadow: ScreenshotShadowStyle(
                    color: RGBAColor(red: 0.25, green: 0.05, blue: 0.10, alpha: 0.32),
                    blurRadius: 44,
                    offsetY: 20
                )
            )
        case .midnight:
            return ScreenshotVisualStyle(
                background: ScreenshotBackgroundStyle(
                    mode: .linearGradient,
                    startColor: RGBAColor(red: 0.05, green: 0.07, blue: 0.14),
                    endColor: RGBAColor(red: 0.18, green: 0.12, blue: 0.35),
                    angleDegrees: 35
                ),
                padding: 108,
                cornerRadius: 30,
                shadow: ScreenshotShadowStyle(
                    color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.58),
                    blurRadius: 52,
                    offsetY: 22
                )
            )
        }
    }
}

public struct ScreenshotVisualLayout: Codable, Sendable, Equatable, Hashable {
    public let outputPixelWidth: Int
    public let outputPixelHeight: Int
    public let cardFrame: ImagePixelRect

    public init(outputPixelWidth: Int, outputPixelHeight: Int, cardFrame: ImagePixelRect) {
        self.outputPixelWidth = outputPixelWidth
        self.outputPixelHeight = outputPixelHeight
        self.cardFrame = cardFrame
    }
}

public enum ScreenshotStyleLayoutPlanningError: Error, Sendable, Equatable {
    case invalidInput
    case outputTooLarge
}

public enum ScreenshotStyleLayoutPlanner {
    public static func makeLayout(
        contentPixelWidth: Int,
        contentPixelHeight: Int,
        style: ScreenshotVisualStyle?,
        maximumPixelCount: Int = MupawConstants.maximumScreenshotPixelCount
    ) throws -> ScreenshotVisualLayout {
        guard contentPixelWidth > 0, contentPixelHeight > 0 else {
            throw ScreenshotStyleLayoutPlanningError.invalidInput
        }
        guard let style else {
            return ScreenshotVisualLayout(
                outputPixelWidth: contentPixelWidth,
                outputPixelHeight: contentPixelHeight,
                cardFrame: ImagePixelRect(
                    x: 0,
                    y: 0,
                    width: Double(contentPixelWidth),
                    height: Double(contentPixelHeight)
                )
            )
        }

        guard style.padding.isFinite, style.padding >= 0,
            style.shadow.blurRadius.isFinite, style.shadow.blurRadius >= 0,
            style.shadow.offsetX.isFinite,
            style.shadow.offsetY.isFinite
        else {
            throw ScreenshotStyleLayoutPlanningError.invalidInput
        }

        let spread = style.shadow.isEnabled ? ceil(style.shadow.blurRadius * 2) : 0
        let leftShadow = style.shadow.isEnabled ? max(0, spread - style.shadow.offsetX) : 0
        let rightShadow = style.shadow.isEnabled ? max(0, spread + style.shadow.offsetX) : 0
        let topShadow = style.shadow.isEnabled ? max(0, spread - style.shadow.offsetY) : 0
        let bottomShadow = style.shadow.isEnabled ? max(0, spread + style.shadow.offsetY) : 0

        let minimumWidth =
            Double(contentPixelWidth) + style.padding * 2 + leftShadow + rightShadow
        let minimumHeight =
            Double(contentPixelHeight) + style.padding * 2 + topShadow + bottomShadow
        guard minimumWidth.isFinite, minimumHeight.isFinite,
            minimumWidth >= 1, minimumHeight >= 1
        else {
            throw ScreenshotStyleLayoutPlanningError.invalidInput
        }

        var outputWidth = minimumWidth
        var outputHeight = minimumHeight
        if let ratio = style.canvasAspect.widthToHeightRatio {
            guard ratio.isFinite, ratio > 0 else {
                throw ScreenshotStyleLayoutPlanningError.invalidInput
            }
            if outputWidth / outputHeight < ratio {
                outputWidth = outputHeight * ratio
            } else {
                outputHeight = outputWidth / ratio
            }
        }

        let pixelWidth = Int(ceil(outputWidth))
        let pixelHeight = Int(ceil(outputHeight))
        guard maximumPixelCount > 0,
            pixelHeight > 0,
            pixelWidth <= maximumPixelCount / pixelHeight
        else {
            throw ScreenshotStyleLayoutPlanningError.outputTooLarge
        }

        let compositionOffsetX = (Double(pixelWidth) - minimumWidth) / 2
        let compositionOffsetY = (Double(pixelHeight) - minimumHeight) / 2
        let cardFrame = ImagePixelRect(
            x: compositionOffsetX + leftShadow + style.padding,
            y: compositionOffsetY + topShadow + style.padding,
            width: Double(contentPixelWidth),
            height: Double(contentPixelHeight)
        )
        return ScreenshotVisualLayout(
            outputPixelWidth: pixelWidth,
            outputPixelHeight: pixelHeight,
            cardFrame: cardFrame
        )
    }
}
