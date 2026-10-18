import CoreGraphics
import Foundation
import ImageIO
import MupawCore
import NaturalLanguage
import Vision

public struct RawOCRObservation: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Double
    public let normalizedBoundingBox: ImagePixelRect

    public init(
        text: String,
        confidence: Double,
        normalizedBoundingBox: ImagePixelRect
    ) {
        self.text = text
        self.confidence = confidence
        self.normalizedBoundingBox = normalizedBoundingBox
    }
}

public struct RawOCRRecognitionResult: Codable, Sendable, Equatable {
    public let engine: OCRRecognitionEngine
    public let effectiveLanguages: [String]
    public let observations: [RawOCRObservation]

    public init(
        engine: OCRRecognitionEngine,
        effectiveLanguages: [String],
        observations: [RawOCRObservation]
    ) {
        self.engine = engine
        self.effectiveLanguages = effectiveLanguages
        self.observations = observations
    }
}

public protocol ScreenshotTextRecognizing: Sendable {
    func recognizeText(
        in image: CGImage,
        level: OCRRecognitionLevel,
        languages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> RawOCRRecognitionResult
}

public struct VisionScreenshotTextRecognizer: ScreenshotTextRecognizing {
    public init() {}

    public func recognizeText(
        in image: CGImage,
        level: OCRRecognitionLevel,
        languages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> RawOCRRecognitionResult {
        try Task.checkCancellation()

        let observations = try autoreleasepool { () throws -> [VNRecognizedTextObservation] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level == .accurate ? .accurate : .fast
            request.usesLanguageCorrection = usesLanguageCorrection
            request.automaticallyDetectsLanguage = languages.isEmpty
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let data = try pngData(for: image)
            let handler = VNImageRequestHandler(data: data, orientation: .up, options: [:])
            try handler.perform([request])
            return request.results ?? []
        }
        try Task.checkCancellation()
        return RawOCRRecognitionResult(
            engine: level == .accurate ? .visionAccurate : .visionFast,
            effectiveLanguages: languages,
            observations: observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let bounds = observation.boundingBox
                return RawOCRObservation(
                    text: candidate.string,
                    confidence: Double(candidate.confidence),
                    normalizedBoundingBox: ImagePixelRect(
                        x: bounds.origin.x,
                        y: bounds.origin.y,
                        width: bounds.width,
                        height: bounds.height
                    )
                )
            }
        )
    }

    private func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            throw ScreenshotProjectServiceError.ocrFailed(
                EditingL10n.string(
                    "analysis.detail.ocr_input_encode_failed",
                    fallback: "The OCR input image could not be encoded."
                )
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotProjectServiceError.ocrFailed(
                EditingL10n.string(
                    "analysis.detail.ocr_input_encode_failed",
                    fallback: "The OCR input image could not be encoded."
                )
            )
        }
        return data as Data
    }
}

struct ScreenshotAnalyzer: Sendable {
    private let textRecognizer: any ScreenshotTextRecognizing

    init(textRecognizer: any ScreenshotTextRecognizing = VisionScreenshotTextRecognizer()) {
        self.textRecognizer = textRecognizer
    }

    func recognizeText(
        record: StoredScreenshotProject,
        originalURL: URL,
        request: ProjectOCRRequest,
        now: Date = Date()
    ) async throws -> ProjectOCRResult {
        let languages = try validatedLanguages(request.recognitionLanguages)
        guard request.minimumConfidence.isFinite,
            request.minimumConfidence >= 0,
            request.minimumConfidence <= 1
        else {
            throw ScreenshotProjectServiceError.invalidAnalysis(
                EditingL10n.string(
                    "analysis.detail.invalid_minimum_confidence",
                    fallback: "OCR minimum confidence must be between 0 and 1."
                )
            )
        }

        let original = try loadImage(at: originalURL)
        let bounds = originalBounds(for: record)
        let region = try validatedRegion(
            request.region ?? record.content.cropRect ?? bounds,
            within: bounds,
            minimumDimension: 2,
            detailKey: "analysis.detail.invalid_ocr_region",
            fallback: "The OCR region must be a finite rectangle fully inside the original image."
        )
        guard let cropped = original.cropping(to: cgRect(region)) else {
            throw ScreenshotProjectServiceError.ocrFailed(
                EditingL10n.string(
                    "analysis.detail.ocr_crop_failed",
                    fallback: "The OCR source region could not be cropped."
                )
            )
        }
        let input = try scaledOCRImage(cropped)

        let rawResult: RawOCRRecognitionResult
        do {
            rawResult = try await textRecognizer.recognizeText(
                in: input,
                level: request.recognitionLevel,
                languages: languages,
                usesLanguageCorrection: request.usesLanguageCorrection
            )
        } catch let error as ScreenshotProjectServiceError {
            throw error
        } catch {
            throw ScreenshotProjectServiceError.ocrFailed(error.localizedDescription)
        }

        let mapped = rawResult.observations.enumerated().compactMap {
            index, raw -> (text: String, confidence: Double, box: ImagePixelRect, language: String, index: Int)? in
            let text = boundedString(
                raw.text.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumUTF8Bytes: MupawConstants.maximumOCRObservationTextUTF8Bytes
            )
            guard !text.isEmpty,
                raw.confidence.isFinite,
                raw.confidence >= request.minimumConfidence,
                let box = mappedOCRBox(raw.normalizedBoundingBox, region: region)
            else {
                return nil
            }
            return (
                text,
                min(max(raw.confidence, 0), 1),
                box,
                detectedLanguage(for: text),
                index
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.box.minY - rhs.box.minY) > 0.5 {
                return lhs.box.minY < rhs.box.minY
            }
            if abs(lhs.box.minX - rhs.box.minX) > 0.5 {
                return lhs.box.minX < rhs.box.minX
            }
            return lhs.index < rhs.index
        }

        var observations: [OCRTextObservation] = []
        observations.reserveCapacity(min(mapped.count, MupawConstants.maximumOCRObservations))
        var combinedBytes = 0
        for item in mapped.prefix(MupawConstants.maximumOCRObservations) {
            let separatorBytes = observations.isEmpty ? 0 : 1
            let nextBytes = item.text.utf8.count + separatorBytes
            guard combinedBytes + nextBytes <= MupawConstants.maximumOCRCombinedTextUTF8Bytes else {
                break
            }
            combinedBytes += nextBytes
            observations.append(
                OCRTextObservation(
                    id: String(format: "ocr-%04d", observations.count + 1),
                    text: item.text,
                    confidence: item.confidence,
                    language: item.language,
                    boundingBox: item.box
                )
            )
        }

        let detectedLanguages = orderedUniqueLanguages(
            observations.map(\.language).filter { $0 != "und" }
        )

        return ProjectOCRResult(
            projectID: record.id,
            projectRevision: record.revision,
            source: .original,
            analyzedRegion: region,
            recognitionLevel: request.recognitionLevel,
            recognitionLanguages: languages,
            usesLanguageCorrection: request.usesLanguageCorrection,
            recognitionEngine: rawResult.engine,
            effectiveRecognitionLanguages: rawResult.effectiveLanguages,
            detectedLanguages: detectedLanguages,
            fullText: observations.map(\.text).joined(separator: "\n"),
            observations: observations,
            createdAt: now
        )
    }

    func sampleColor(
        record: StoredScreenshotProject,
        originalURL: URL,
        request: ProjectColorSampleRequest,
        now: Date = Date()
    ) throws -> ProjectColorSampleResult {
        let original = try loadImage(at: originalURL)
        let bounds = originalBounds(for: record)

        switch request.mode {
        case .point:
            guard request.region == nil,
                let requestedPoint = request.point,
                requestedPoint.isFinite,
                requestedPoint.x >= bounds.minX,
                requestedPoint.y >= bounds.minY,
                requestedPoint.x < bounds.maxX,
                requestedPoint.y < bounds.maxY
            else {
                throw ScreenshotProjectServiceError.invalidAnalysis(
                    EditingL10n.string(
                        "analysis.detail.invalid_color_point",
                        fallback:
                            "Point color sampling requires one finite point inside the original image and no region."
                    )
                )
            }
            let point = ImagePixelPoint(
                x: floor(requestedPoint.x),
                y: floor(requestedPoint.y)
            )
            let color = try samplePoint(point, image: original)
            return ProjectColorSampleResult(
                projectID: record.id,
                projectRevision: record.revision,
                source: .original,
                mode: .point,
                point: point,
                region: nil,
                primaryColor: SampledColor(rgba: color),
                averageColor: nil,
                centerColor: nil,
                dominantColor: nil,
                sampledPixelCount: 1,
                createdAt: now
            )

        case .region:
            guard request.point == nil else {
                throw ScreenshotProjectServiceError.invalidAnalysis(
                    EditingL10n.string(
                        "analysis.detail.invalid_color_region",
                        fallback: "Region color sampling accepts a region and no point."
                    )
                )
            }
            let region = try validatedRegion(
                request.region ?? record.content.cropRect ?? bounds,
                within: bounds,
                minimumDimension: 1,
                detailKey: "analysis.detail.invalid_color_region",
                fallback: "The color sampling region must be a finite rectangle fully inside the original image."
            )
            let statistics = try sampleRegion(region, image: original)
            let average = SampledColor(rgba: statistics.average)
            return ProjectColorSampleResult(
                projectID: record.id,
                projectRevision: record.revision,
                source: .original,
                mode: .region,
                point: nil,
                region: region,
                primaryColor: average,
                averageColor: average,
                centerColor: SampledColor(rgba: statistics.center),
                dominantColor: SampledColor(rgba: statistics.dominant),
                sampledPixelCount: statistics.sampleCount,
                createdAt: now
            )
        }
    }

    private func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ScreenshotProjectServiceError.unsupportedImage
        }
        return image
    }

    private func originalBounds(for record: StoredScreenshotProject) -> ImagePixelRect {
        ImagePixelRect(
            x: 0,
            y: 0,
            width: Double(record.originalPixelWidth),
            height: Double(record.originalPixelHeight)
        )
    }

    private func validatedRegion(
        _ requested: ImagePixelRect,
        within bounds: ImagePixelRect,
        minimumDimension: Double,
        detailKey: String,
        fallback: String
    ) throws -> ImagePixelRect {
        let value = requested.standardized
        guard value.isFinite,
            value.width >= minimumDimension,
            value.height >= minimumDimension,
            bounds.contains(value)
        else {
            throw ScreenshotProjectServiceError.invalidAnalysis(
                EditingL10n.string(detailKey, fallback: fallback)
            )
        }

        let minX = max(bounds.minX, floor(value.minX))
        let minY = max(bounds.minY, floor(value.minY))
        let maxX = min(bounds.maxX, ceil(value.maxX))
        let maxY = min(bounds.maxY, ceil(value.maxY))
        let integral = ImagePixelRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard integral.width >= minimumDimension, integral.height >= minimumDimension else {
            throw ScreenshotProjectServiceError.invalidAnalysis(
                EditingL10n.string(detailKey, fallback: fallback)
            )
        }
        return integral
    }

    private func validatedLanguages(_ languages: [String]) throws -> [String] {
        guard languages.count <= MupawConstants.maximumOCRLanguages else {
            throw ScreenshotProjectServiceError.invalidAnalysis(
                EditingL10n.format(
                    "analysis.detail.too_many_languages.format",
                    fallback: "OCR accepts at most %d language hints.",
                    MupawConstants.maximumOCRLanguages
                )
            )
        }

        var result: [String] = []
        var seen = Set<String>()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for language in languages {
            let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                value.utf8.count <= MupawConstants.maximumOCRLanguageTagUTF8Bytes,
                value.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else {
                throw ScreenshotProjectServiceError.invalidAnalysis(
                    EditingL10n.string(
                        "analysis.detail.invalid_language_hint",
                        fallback: "OCR language hints must be short BCP-47 style identifiers."
                    )
                )
            }
            let key = value.lowercased()
            if seen.insert(key).inserted {
                result.append(value)
            }
        }
        return result
    }

    private func scaledOCRImage(_ image: CGImage) throws -> CGImage {
        let maximum = MupawConstants.maximumOCRInputDimension
        let largest = max(image.width, image.height)
        guard largest > maximum else { return image }
        let scale = Double(maximum) / Double(largest)
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
            throw ScreenshotProjectServiceError.ocrFailed(
                EditingL10n.string(
                    "analysis.detail.ocr_scale_context_failed",
                    fallback: "The OCR scaling context could not be created."
                )
            )
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw ScreenshotProjectServiceError.ocrFailed(
                EditingL10n.string(
                    "analysis.detail.ocr_scale_image_failed",
                    fallback: "The OCR input image could not be created."
                )
            )
        }
        return scaled
    }

    private func mappedOCRBox(
        _ normalized: ImagePixelRect,
        region: ImagePixelRect
    ) -> ImagePixelRect? {
        let value = normalized.standardized
        guard value.isFinite, value.width > 0, value.height > 0 else { return nil }
        let minX = min(max(value.minX, 0), 1)
        let maxX = min(max(value.maxX, 0), 1)
        let minY = min(max(value.minY, 0), 1)
        let maxY = min(max(value.maxY, 0), 1)
        guard maxX > minX, maxY > minY else { return nil }

        let rect = ImagePixelRect(
            x: region.minX + minX * region.width,
            y: region.minY + (1 - maxY) * region.height,
            width: (maxX - minX) * region.width,
            height: (maxY - minY) * region.height
        )
        return rect.intersection(region)
    }

    private func boundedString(_ string: String, maximumUTF8Bytes: Int) -> String {
        guard string.utf8.count > maximumUTF8Bytes else { return string }
        var result = ""
        result.reserveCapacity(min(string.count, maximumUTF8Bytes))
        var byteCount = 0
        for character in string {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result
    }

    private func detectedLanguage(for text: String) -> String {
        let letterScalars = text.unicodeScalars.filter(CharacterSet.letters.contains)
        guard !letterScalars.isEmpty else {
            return "und"
        }
        let asciiLetterCount = letterScalars.lazy.filter {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }.count
        let nonASCIILetterCount = letterScalars.count - asciiLetterCount
        guard
            nonASCIILetterCount >= 2
                || asciiLetterCount >= MupawConstants.minimumOCRASCIILettersForLanguageIdentification
        else {
            return "und"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
            hypothesis.value >= MupawConstants.minimumOCRLanguageIdentificationConfidence
        else {
            return "und"
        }
        return hypothesis.key.rawValue
    }

    private func orderedUniqueLanguages(_ languages: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for language in languages where seen.insert(language.lowercased()).inserted {
            result.append(language)
        }
        return result
    }

    private func samplePoint(_ point: ImagePixelPoint, image: CGImage) throws -> RGBAColor {
        guard
            let cropped = image.cropping(
                to: CGRect(x: point.x, y: point.y, width: 1, height: 1)
            )
        else {
            throw ScreenshotProjectServiceError.colorSamplingFailed(
                EditingL10n.string(
                    "analysis.detail.point_crop_failed",
                    fallback: "The color sampling pixel could not be cropped."
                )
            )
        }
        let pixels = try renderedPixels(image: cropped, width: 1, height: 1)
        return unpremultipliedColor(
            red: pixels[0],
            green: pixels[1],
            blue: pixels[2],
            alpha: pixels[3]
        )
    }

    private func sampleRegion(
        _ region: ImagePixelRect,
        image: CGImage
    ) throws -> (average: RGBAColor, center: RGBAColor, dominant: RGBAColor, sampleCount: Int) {
        guard let cropped = image.cropping(to: cgRect(region)) else {
            throw ScreenshotProjectServiceError.colorSamplingFailed(
                EditingL10n.string(
                    "analysis.detail.region_crop_failed",
                    fallback: "The color sampling region could not be cropped."
                )
            )
        }

        let maximumDimension = Double(MupawConstants.maximumColorSampleDimension)
        let dimensionScale = min(
            1,
            minimum(
                maximumDimension / Double(cropped.width),
                maximumDimension / Double(cropped.height)
            )
        )
        let pixelScale = min(
            1,
            sqrt(
                Double(MupawConstants.maximumColorSamplePixels)
                    / Double(max(1, cropped.width * cropped.height))
            )
        )
        let scale = min(dimensionScale, pixelScale)
        let width = max(1, Int((Double(cropped.width) * scale).rounded()))
        let height = max(1, Int((Double(cropped.height) * scale).rounded()))
        let pixels = try renderedPixels(image: cropped, width: width, height: height)

        var alphaSum = 0.0
        var premultipliedRedSum = 0.0
        var premultipliedGreenSum = 0.0
        var premultipliedBlueSum = 0.0
        var buckets: [Int: ColorBucket] = [:]
        buckets.reserveCapacity(512)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let redByte = pixels[index]
            let greenByte = pixels[index + 1]
            let blueByte = pixels[index + 2]
            let alphaByte = pixels[index + 3]
            let alpha = Double(alphaByte) / 255
            alphaSum += alpha
            premultipliedRedSum += Double(redByte) / 255
            premultipliedGreenSum += Double(greenByte) / 255
            premultipliedBlueSum += Double(blueByte) / 255

            guard alphaByte >= 4 else { continue }
            let color = unpremultipliedColor(
                red: redByte,
                green: greenByte,
                blue: blueByte,
                alpha: alphaByte
            )
            let redBin = min(31, Int(color.red * 31))
            let greenBin = min(31, Int(color.green * 31))
            let blueBin = min(31, Int(color.blue * 31))
            let key = (redBin << 10) | (greenBin << 5) | blueBin
            var bucket = buckets[key] ?? ColorBucket()
            bucket.count += 1
            bucket.red += color.red
            bucket.green += color.green
            bucket.blue += color.blue
            bucket.alpha += color.alpha
            buckets[key] = bucket
        }

        let sampleCount = width * height
        let averageAlpha = alphaSum / Double(sampleCount)
        let average = RGBAColor(
            red: averageAlpha > 0 ? min(1, premultipliedRedSum / Double(sampleCount) / averageAlpha) : 0,
            green: averageAlpha > 0 ? min(1, premultipliedGreenSum / Double(sampleCount) / averageAlpha) : 0,
            blue: averageAlpha > 0 ? min(1, premultipliedBlueSum / Double(sampleCount) / averageAlpha) : 0,
            alpha: min(max(averageAlpha, 0), 1)
        )

        let dominantEntry = buckets.max { lhs, rhs in
            lhs.value.count == rhs.value.count
                ? lhs.key > rhs.key
                : lhs.value.count < rhs.value.count
        }
        let dominant: RGBAColor
        if let bucket = dominantEntry?.value, bucket.count > 0 {
            dominant = RGBAColor(
                red: bucket.red / Double(bucket.count),
                green: bucket.green / Double(bucket.count),
                blue: bucket.blue / Double(bucket.count),
                alpha: bucket.alpha / Double(bucket.count)
            )
        } else {
            dominant = average
        }

        let center = try samplePoint(
            ImagePixelPoint(
                x: min(region.maxX - 1, floor(region.minX + region.width / 2)),
                y: min(region.maxY - 1, floor(region.minY + region.height / 2))
            ),
            image: image
        )
        return (average, center, dominant, sampleCount)
    }

    private func renderedPixels(image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let created = data.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:
                        CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else {
            throw ScreenshotProjectServiceError.colorSamplingFailed(
                EditingL10n.string(
                    "analysis.detail.pixel_context_failed",
                    fallback: "The color sampling pixel context could not be created."
                )
            )
        }
        return data
    }

    private func unpremultipliedColor(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) -> RGBAColor {
        let normalizedAlpha = Double(alpha) / 255
        guard normalizedAlpha > 0 else {
            return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return RGBAColor(
            red: min(1, Double(red) / 255 / normalizedAlpha),
            green: min(1, Double(green) / 255 / normalizedAlpha),
            blue: min(1, Double(blue) / 255 / normalizedAlpha),
            alpha: normalizedAlpha
        )
    }

    private func cgRect(_ rect: ImagePixelRect) -> CGRect {
        let value = rect.standardized
        return CGRect(x: value.minX, y: value.minY, width: value.width, height: value.height)
    }

    private func minimum(_ first: Double, _ second: Double) -> Double {
        min(first, second)
    }
}

private struct ColorBucket {
    var count = 0
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var alpha = 0.0
}
