import AVFoundation
import CoreGraphics
import Foundation

private struct PixelFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func rgb(x: Int, y: Int) -> (Double, Double, Double) {
        let clampedX = max(0, min(width - 1, x))
        let clampedY = max(0, min(height - 1, y))
        let offset = (clampedY * width + clampedX) * 4
        return (
            Double(bytes[offset]) / 255,
            Double(bytes[offset + 1]) / 255,
            Double(bytes[offset + 2]) / 255
        )
    }

    func luminance(x: Int, y: Int) -> Double {
        let (red, green, blue) = rgb(x: x, y: y)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

private struct RegionStats {
    let meanLuminance: Double
    let variance: Double
    let edgeEnergy: Double
    let sampleCount: Int
}

@main
enum InspectCameraOverlay {
    static func main() async {
        guard CommandLine.arguments.count == 6,
            let x = Int(CommandLine.arguments[2]),
            let y = Int(CommandLine.arguments[3]),
            let width = Int(CommandLine.arguments[4]),
            let height = Int(CommandLine.arguments[5])
        else {
            fputs("usage: inspect_camera_overlay <path> <x> <y> <width> <height>\n", stderr)
            exit(2)
        }

        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                throw NSError(
                    domain: "MupawCameraOverlayInspector",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The video duration is invalid."]
                )
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            let positions = [0.25, 0.5, 0.75]
            var frames: [PixelFrame] = []
            for position in positions {
                let image = try await generator.image(
                    at: CMTime(seconds: seconds * position, preferredTimescale: 600)
                ).image
                frames.append(try pixelFrame(image))
            }
            guard let first = frames.first else {
                throw NSError(
                    domain: "MupawCameraOverlayInspector",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No video frames were decoded."]
                )
            }
            guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
                throw NSError(
                    domain: "MupawCameraOverlayInspector",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Decoded frame dimensions changed."]
                )
            }

            let overlay = CGRect(x: x, y: y, width: width, height: height).integral
            guard overlay.minX >= 0, overlay.minY >= 0,
                overlay.maxX <= Double(first.width), overlay.maxY <= Double(first.height),
                overlay.width >= 16, overlay.height >= 16
            else {
                throw NSError(
                    domain: "MupawCameraOverlayInspector",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "The overlay rectangle is outside the video frame."]
                )
            }
            let control = CGRect(
                x: Double(first.width) - overlay.maxX,
                y: Double(first.height) - overlay.maxY,
                width: overlay.width,
                height: overlay.height
            ).integral

            let overlayStats = frames.map { stats(frame: $0, rect: overlay) }
            let controlStats = frames.map { stats(frame: $0, rect: control) }
            let spatialDifferences = frames.map {
                meanAbsoluteDifference(frame: $0, first: overlay, second: control)
            }
            let temporalDifferences = zip(frames, frames.dropFirst()).map {
                meanAbsoluteDifference(firstFrame: $0, secondFrame: $1, rect: overlay)
            }

            let payload: [String: Any] = [
                "pixelWidth": first.width,
                "pixelHeight": first.height,
                "frameSamples": frames.count,
                "overlayRect": rectObject(overlay),
                "controlRect": rectObject(control),
                "overlayMeanLuminance": overlayStats.map(\.meanLuminance),
                "controlMeanLuminance": controlStats.map(\.meanLuminance),
                "overlayVariance": overlayStats.map(\.variance),
                "controlVariance": controlStats.map(\.variance),
                "overlayEdgeEnergy": overlayStats.map(\.edgeEnergy),
                "controlEdgeEnergy": controlStats.map(\.edgeEnergy),
                "spatialMeanAbsoluteDifference": spatialDifferences,
                "temporalMeanAbsoluteDifference": temporalDifferences,
                "sampleCount": overlayStats.first?.sampleCount ?? 0,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("inspect_camera_overlay failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func pixelFrame(_ image: CGImage) throws -> PixelFrame {
        let width = image.width
        let height = image.height
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "MupawCameraOverlayInspector",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not create a pixel context."]
            )
        }
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelFrame(width: width, height: height, bytes: bytes)
    }

    private static func stats(frame: PixelFrame, rect: CGRect) -> RegionStats {
        let step = max(1, Int(min(rect.width, rect.height) / 96))
        let minX = max(0, Int(rect.minX))
        let minY = max(0, Int(rect.minY))
        let maxX = min(frame.width, Int(rect.maxX))
        let maxY = min(frame.height, Int(rect.maxY))
        var sum = 0.0
        var sumSquares = 0.0
        var edge = 0.0
        var count = 0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                let value = frame.luminance(x: x, y: y)
                sum += value
                sumSquares += value * value
                if x + step < maxX {
                    edge += abs(value - frame.luminance(x: x + step, y: y))
                }
                if y + step < maxY {
                    edge += abs(value - frame.luminance(x: x, y: y + step))
                }
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return RegionStats(meanLuminance: 0, variance: 0, edgeEnergy: 0, sampleCount: 0) }
        let mean = sum / Double(count)
        return RegionStats(
            meanLuminance: mean,
            variance: max(0, sumSquares / Double(count) - mean * mean),
            edgeEnergy: edge / Double(max(1, count * 2)),
            sampleCount: count
        )
    }

    private static func meanAbsoluteDifference(
        frame: PixelFrame,
        first: CGRect,
        second: CGRect
    ) -> Double {
        let step = max(1, Int(min(first.width, first.height) / 96))
        var sum = 0.0
        var count = 0
        var localY = 0
        while localY < Int(first.height) {
            var localX = 0
            while localX < Int(first.width) {
                let firstRGB = frame.rgb(
                    x: Int(first.minX) + localX,
                    y: Int(first.minY) + localY
                )
                let secondRGB = frame.rgb(
                    x: Int(second.minX) + localX,
                    y: Int(second.minY) + localY
                )
                sum += (
                    abs(firstRGB.0 - secondRGB.0)
                        + abs(firstRGB.1 - secondRGB.1)
                        + abs(firstRGB.2 - secondRGB.2)
                ) / 3
                count += 1
                localX += step
            }
            localY += step
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func meanAbsoluteDifference(
        firstFrame: PixelFrame,
        secondFrame: PixelFrame,
        rect: CGRect
    ) -> Double {
        let step = max(1, Int(min(rect.width, rect.height) / 96))
        var sum = 0.0
        var count = 0
        var y = Int(rect.minY)
        while y < Int(rect.maxY) {
            var x = Int(rect.minX)
            while x < Int(rect.maxX) {
                let first = firstFrame.rgb(x: x, y: y)
                let second = secondFrame.rgb(x: x, y: y)
                sum += (
                    abs(first.0 - second.0)
                        + abs(first.1 - second.1)
                        + abs(first.2 - second.2)
                ) / 3
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func rectObject(_ rect: CGRect) -> [String: Int] {
        [
            "x": Int(rect.minX),
            "y": Int(rect.minY),
            "width": Int(rect.width),
            "height": Int(rect.height),
        ]
    }
}
