import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MupawCore
import UniformTypeIdentifiers

public enum ImageArtifactEncoderError: Error, LocalizedError {
    case destinationCreationFailed
    case imageEncodingFailed
    case previewContextCreationFailed

    public var errorDescription: String? {
        switch self {
        case .destinationCreationFailed:
            return "Could not create an image destination."
        case .imageEncodingFailed:
            return "Could not encode the captured image."
        case .previewContextCreationFailed:
            return "Could not create the image preview context."
        }
    }
}

public enum ImageArtifactEncoder {
    public static func writePNG(
        image: CGImage,
        source: CaptureSourceDescriptor,
        request: ScreenshotRequest,
        paths: MupawPaths,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> ScreenshotArtifact {
        try paths.prepare(fileManager: fileManager)

        let artifactID = UUID().uuidString.lowercased()
        let fallback = "Mupaw-\(timestamp(now))"
        let baseName = FileNameSanitizer.sanitizedBaseName(request.fileName, fallback: fallback)
        let fileURL = uniqueFileURL(
            directory: paths.capturesDirectory,
            baseName: baseName,
            extension: "png",
            fileManager: fileManager
        )

        let data = try encodedData(image: image, type: .png, properties: [:])
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let preview = try makePreview(image: image)

        return ScreenshotArtifact(
            id: artifactID,
            source: source,
            format: .png,
            fileURL: fileURL,
            pixelWidth: image.width,
            pixelHeight: image.height,
            byteCount: data.count,
            sha256: digest,
            createdAt: now,
            preview: preview
        )
    }

    public static func makePreview(image: CGImage) throws -> ImagePreview {
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
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ImageArtifactEncoderError.previewContextCreationFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let previewImage = context.makeImage() else {
            throw ImageArtifactEncoderError.previewContextCreationFailed
        }

        let data = try encodedData(
            image: previewImage,
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

    private static func encodedData(
        image: CGImage,
        type: UTType,
        properties: [CFString: Any]
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                mutableData,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            throw ImageArtifactEncoderError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageArtifactEncoderError.imageEncodingFailed
        }
        return mutableData as Data
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
