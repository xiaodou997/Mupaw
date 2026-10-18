import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import MupawCore
import UniformTypeIdentifiers

struct ScreenshotRenderer: Sendable {
    func render(
        record: StoredScreenshotProject,
        originalURL: URL
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
            let original = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ScreenshotProjectServiceError.unsupportedImage
        }

        let originalBounds = ImagePixelRect(
            x: 0,
            y: 0,
            width: Double(original.width),
            height: Double(original.height)
        )
        let requestedCrop = record.content.cropRect?.standardized ?? originalBounds
        guard let clippedCrop = requestedCrop.intersection(originalBounds) else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.string(
                    "editing.detail.crop_no_intersection",
                    fallback: "The crop does not intersect the source image."
                )
            )
        }

        let cropRect = integralCrop(clippedCrop, within: originalBounds)
        let width = Int(cropRect.width)
        let height = Int(cropRect.height)
        try ScreenshotProjectStore.validateCanvas(width: width, height: height)

        guard
            let cropped = original.cropping(
                to: CGRect(x: cropRect.x, y: cropRect.y, width: cropRect.width, height: cropRect.height)
            )
        else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.source_crop_failed",
                    fallback: "The source image could not be cropped."
                )
            )
        }

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.render_context_failed",
                    fallback: "The render context could not be created."
                )
            )
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        for object in record.content.objects {
            switch object {
            case .arrow(let arrow):
                drawArrow(arrow, crop: cropRect, outputHeight: Double(height), context: context)
            case .text(let text):
                drawText(text, crop: cropRect, outputHeight: Double(height), context: context)
            case .mosaic(let mosaic):
                try drawMosaic(
                    mosaic,
                    crop: cropRect,
                    outputWidth: width,
                    outputHeight: height,
                    context: context
                )
            }
        }

        guard let image = context.makeImage() else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.final_image_failed",
                    fallback: "The final image could not be created."
                )
            )
        }
        return image
    }

    func preview(
        image: CGImage,
        projectID: String,
        revision: Int
    ) throws -> ProjectPreviewResult {
        let preview = try EditingImageEncoder.preview(image: image)
        return ProjectPreviewResult(
            projectID: projectID,
            revision: revision,
            pixelWidth: image.width,
            pixelHeight: image.height,
            preview: preview
        )
    }

    private func integralCrop(
        _ rect: ImagePixelRect,
        within bounds: ImagePixelRect
    ) -> ImagePixelRect {
        let value = rect.standardized
        let outer = bounds.standardized
        let minX = max(outer.minX, floor(value.minX))
        let minY = max(outer.minY, floor(value.minY))
        let maxX = min(outer.maxX, ceil(value.maxX))
        let maxY = min(outer.maxY, ceil(value.maxY))
        return ImagePixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func outputPoint(
        _ point: ImagePixelPoint,
        crop: ImagePixelRect,
        outputHeight: Double
    ) -> CGPoint {
        CGPoint(
            x: point.x - crop.minX,
            y: outputHeight - (point.y - crop.minY)
        )
    }

    private func outputRect(
        _ rect: ImagePixelRect,
        crop: ImagePixelRect,
        outputHeight: Double
    ) -> CGRect {
        let value = rect.standardized
        return CGRect(
            x: value.minX - crop.minX,
            y: outputHeight - (value.maxY - crop.minY),
            width: value.width,
            height: value.height
        )
    }

    private func drawArrow(
        _ arrow: ArrowEdit,
        crop: ImagePixelRect,
        outputHeight: Double,
        context: CGContext
    ) {
        let start = outputPoint(arrow.start, crop: crop, outputHeight: outputHeight)
        let end = outputPoint(arrow.end, crop: crop, outputHeight: outputHeight)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let color = cgColor(arrow.color)
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(arrow.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(dy, dx)
        let headLength = max(arrow.lineWidth * 4, 18)
        let spread = CGFloat.pi / 6
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private func drawText(
        _ text: TextEdit,
        crop: ImagePixelRect,
        outputHeight: Double,
        context: CGContext
    ) {
        let frame = outputRect(text.frame, crop: crop, outputHeight: outputHeight)
        guard frame.width > 0, frame.height > 0 else { return }

        let font = CTFontCreateWithName("Helvetica Neue" as CFString, text.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(text.color),
        ]
        let attributed = NSAttributedString(string: text.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: frame, transform: nil)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )

        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }

    private func drawMosaic(
        _ mosaic: MosaicEdit,
        crop: ImagePixelRect,
        outputWidth: Int,
        outputHeight: Int,
        context: CGContext
    ) throws {
        guard let intersection = mosaic.frame.standardized.intersection(crop),
            let current = context.makeImage()
        else {
            return
        }

        let region = outputRect(
            intersection,
            crop: crop,
            outputHeight: Double(outputHeight)
        ).intersection(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard region.width >= 1, region.height >= 1 else { return }

        let integralRegion = region.integral.intersection(
            CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        )
        guard integralRegion.width >= 1, integralRegion.height >= 1 else { return }

        let imageCropRect = CGRect(
            x: integralRegion.minX,
            y: CGFloat(outputHeight) - integralRegion.maxY,
            width: integralRegion.width,
            height: integralRegion.height
        ).integral
        guard let cropped = current.cropping(to: imageCropRect) else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.mosaic_source_crop_failed",
                    fallback: "The mosaic source region could not be cropped."
                )
            )
        }

        let sampleWidth = max(1, Int(ceil(integralRegion.width / mosaic.blockSize)))
        let sampleHeight = max(1, Int(ceil(integralRegion.height / mosaic.blockSize)))
        guard
            let sampleContext = CGContext(
                data: nil,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.mosaic_sample_context_failed",
                    fallback: "The mosaic sample context could not be created."
                )
            )
        }
        sampleContext.interpolationQuality = .low
        sampleContext.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight)
        )
        guard let sampled = sampleContext.makeImage() else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.mosaic_sample_image_failed",
                    fallback: "The mosaic sample image could not be created."
                )
            )
        }

        context.saveGState()
        context.interpolationQuality = .none
        context.draw(sampled, in: integralRegion)
        context.restoreGState()
    }

    private func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [color.red, color.green, color.blue, color.alpha]
        ) ?? CGColor(gray: 0, alpha: 1)
    }
}

enum EditingImageEncoder {
    static func preview(image: CGImage) throws -> ImagePreview {
        let maximum = MupawConstants.previewMaximumDimension
        let scale = min(
            1,
            min(Double(maximum) / Double(image.width), Double(maximum) / Double(image.height))
        )
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.preview_context_failed",
                    fallback: "The preview context could not be created."
                )
            )
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.preview_image_failed",
                    fallback: "The preview image could not be created."
                )
            )
        }
        let data = try encodedData(
            image: scaled,
            type: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: 0.82]
        )
        return ImagePreview(
            mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
            base64Data: data.base64EncodedString(),
            pixelWidth: width,
            pixelHeight: height
        )
    }

    static func exportPNG(
        image: CGImage,
        record: StoredScreenshotProject,
        fileName: String?,
        paths: MupawPaths,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> ProjectExportArtifact {
        try paths.prepare(fileManager: fileManager)
        let fallback = "Mupaw-Edited-\(timestamp(now))"
        let baseName = FileNameSanitizer.sanitizedBaseName(fileName, fallback: fallback)
        let fileURL = uniqueFileURL(
            directory: paths.exportsDirectory,
            baseName: baseName,
            extension: "png",
            fileManager: fileManager
        )
        let data = try encodedData(image: image, type: .png, properties: [:])
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ProjectExportArtifact(
            id: UUID().uuidString.lowercased(),
            projectID: record.id,
            projectRevision: record.revision,
            fileURL: fileURL,
            pixelWidth: image.width,
            pixelHeight: image.height,
            byteCount: data.count,
            sha256: digest,
            createdAt: now,
            preview: try preview(image: image)
        )
    }

    private static func encodedData(
        image: CGImage,
        type: UTType,
        properties: [CFString: Any]
    ) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.image_destination_failed",
                    fallback: "The image destination could not be created."
                )
            )
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotProjectServiceError.renderFailed(
                EditingL10n.string(
                    "editing.detail.image_encode_failed",
                    fallback: "The image could not be encoded."
                )
            )
        }
        return data as Data
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func uniqueFileURL(
        directory: URL,
        baseName: String,
        extension fileExtension: String,
        fileManager: FileManager
    ) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate =
                directory
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
