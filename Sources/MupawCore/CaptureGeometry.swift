import Foundation

public enum ScreenshotCaptureMode: String, Codable, Sendable, CaseIterable, Hashable {
    case fullScreen = "full_screen"
    case window
    case region
}

public enum CaptureCoordinateSpace: String, Codable, Sendable, Hashable {
    case globalDisplayPoints = "global_display_points"
}

public struct CaptureRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { min(x, x + width) }
    public var maxX: Double { max(x, x + width) }
    public var minY: Double { min(y, y + height) }
    public var maxY: Double { max(y, y + height) }

    public var standardized: CaptureRect {
        CaptureRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    public var hasPositiveArea: Bool {
        let value = standardized
        return value.width > 0 && value.height > 0
    }

    public func intersection(_ other: CaptureRect) -> CaptureRect? {
        let left = max(standardized.minX, other.standardized.minX)
        let top = max(standardized.minY, other.standardized.minY)
        let right = min(standardized.maxX, other.standardized.maxX)
        let bottom = min(standardized.maxY, other.standardized.maxY)
        guard right > left, bottom > top else { return nil }
        return CaptureRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

public struct CaptureRegion: Codable, Sendable, Equatable {
    public let coordinateSpace: CaptureCoordinateSpace
    public let rect: CaptureRect

    public init(
        coordinateSpace: CaptureCoordinateSpace = .globalDisplayPoints,
        rect: CaptureRect
    ) {
        self.coordinateSpace = coordinateSpace
        self.rect = rect
    }
}

public struct CapturePixelRect: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CaptureDisplayGeometry: Codable, Sendable, Equatable {
    public let sourceID: String
    public let framePoints: CaptureRect
    public let pointPixelScale: Double

    public init(sourceID: String, framePoints: CaptureRect, pointPixelScale: Double) {
        self.sourceID = sourceID
        self.framePoints = framePoints
        self.pointPixelScale = pointPixelScale
    }
}

public struct RegionCaptureSlice: Codable, Sendable, Equatable {
    public let sourceID: String
    public let sourceRectPoints: CaptureRect
    public let destinationPixelRect: CapturePixelRect

    public init(
        sourceID: String,
        sourceRectPoints: CaptureRect,
        destinationPixelRect: CapturePixelRect
    ) {
        self.sourceID = sourceID
        self.sourceRectPoints = sourceRectPoints
        self.destinationPixelRect = destinationPixelRect
    }
}

public struct RegionCapturePlan: Codable, Sendable, Equatable {
    public let region: CaptureRegion
    public let outputPixelWidth: Int
    public let outputPixelHeight: Int
    public let outputPointPixelScale: Double
    public let slices: [RegionCaptureSlice]

    public init(
        region: CaptureRegion,
        outputPixelWidth: Int,
        outputPixelHeight: Int,
        outputPointPixelScale: Double,
        slices: [RegionCaptureSlice]
    ) {
        self.region = region
        self.outputPixelWidth = outputPixelWidth
        self.outputPixelHeight = outputPixelHeight
        self.outputPointPixelScale = outputPointPixelScale
        self.slices = slices
    }
}

public enum RegionCapturePlanningError: Error, Sendable, Equatable {
    case unsupportedCoordinateSpace
    case invalidRegion
    case noDisplayIntersection
    case invalidDisplayGeometry(String)
    case outputTooLarge
}

public enum RegionCapturePlanner {
    public static func makePlan(
        region: CaptureRegion,
        displays: [CaptureDisplayGeometry],
        maximumPixelCount: Int = MupawConstants.maximumScreenshotPixelCount
    ) throws -> RegionCapturePlan {
        guard region.coordinateSpace == .globalDisplayPoints else {
            throw RegionCapturePlanningError.unsupportedCoordinateSpace
        }

        let rect = region.rect.standardized
        guard rect.isFinite, rect.hasPositiveArea else {
            throw RegionCapturePlanningError.invalidRegion
        }

        let intersections: [(CaptureDisplayGeometry, CaptureRect)] = try displays.compactMap { display in
            let frame = display.framePoints.standardized
            guard frame.isFinite, frame.hasPositiveArea,
                display.pointPixelScale.isFinite, display.pointPixelScale > 0
            else {
                throw RegionCapturePlanningError.invalidDisplayGeometry(display.sourceID)
            }
            guard let intersection = rect.intersection(frame) else { return nil }
            return (display, intersection)
        }

        guard !intersections.isEmpty else {
            throw RegionCapturePlanningError.noDisplayIntersection
        }

        let outputScale = intersections.map { $0.0.pointPixelScale }.max() ?? 1
        let rawWidth = ceil(rect.width * outputScale)
        let rawHeight = ceil(rect.height * outputScale)
        guard rawWidth.isFinite, rawHeight.isFinite,
            rawWidth >= 1, rawHeight >= 1,
            rawWidth <= Double(Int.max), rawHeight <= Double(Int.max)
        else {
            throw RegionCapturePlanningError.outputTooLarge
        }

        let outputWidth = Int(rawWidth)
        let outputHeight = Int(rawHeight)
        guard maximumPixelCount > 0,
            outputHeight == 0 || outputWidth <= maximumPixelCount / outputHeight
        else {
            throw RegionCapturePlanningError.outputTooLarge
        }

        let slices =
            intersections
            .sorted {
                if $0.1.minY == $1.1.minY {
                    return $0.1.minX < $1.1.minX
                }
                return $0.1.minY < $1.1.minY
            }
            .compactMap { display, intersection -> RegionCaptureSlice? in
                let left = Int(((intersection.minX - rect.minX) * outputScale).rounded())
                let right = Int(((intersection.maxX - rect.minX) * outputScale).rounded())
                let top = Int(((intersection.minY - rect.minY) * outputScale).rounded())
                let bottom = Int(((intersection.maxY - rect.minY) * outputScale).rounded())
                let clampedLeft = max(0, min(outputWidth, left))
                let clampedRight = max(0, min(outputWidth, right))
                let clampedTop = max(0, min(outputHeight, top))
                let clampedBottom = max(0, min(outputHeight, bottom))
                let destination = CapturePixelRect(
                    x: clampedLeft,
                    y: clampedTop,
                    width: max(0, clampedRight - clampedLeft),
                    height: max(0, clampedBottom - clampedTop)
                )
                guard destination.width > 0, destination.height > 0 else { return nil }

                return RegionCaptureSlice(
                    sourceID: display.sourceID,
                    sourceRectPoints: CaptureRect(
                        x: intersection.minX - display.framePoints.standardized.minX,
                        y: intersection.minY - display.framePoints.standardized.minY,
                        width: intersection.width,
                        height: intersection.height
                    ),
                    destinationPixelRect: destination
                )
            }

        guard !slices.isEmpty else {
            throw RegionCapturePlanningError.noDisplayIntersection
        }

        return RegionCapturePlan(
            region: CaptureRegion(coordinateSpace: region.coordinateSpace, rect: rect),
            outputPixelWidth: outputWidth,
            outputPixelHeight: outputHeight,
            outputPointPixelScale: outputScale,
            slices: slices
        )
    }
}

public enum GlobalDisplayCoordinateMapper {
    public static func appKitToGlobalDisplay(
        _ rect: CaptureRect,
        primaryScreenMaxY: Double
    ) -> CaptureRect {
        let value = rect.standardized
        return CaptureRect(
            x: value.minX,
            y: primaryScreenMaxY - value.maxY,
            width: value.width,
            height: value.height
        )
    }

    public static func globalDisplayToAppKit(
        _ rect: CaptureRect,
        primaryScreenMaxY: Double
    ) -> CaptureRect {
        let value = rect.standardized
        return CaptureRect(
            x: value.minX,
            y: primaryScreenMaxY - value.maxY,
            width: value.width,
            height: value.height
        )
    }
}
