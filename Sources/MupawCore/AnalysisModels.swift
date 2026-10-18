import Foundation

public enum ProjectAnalysisSource: String, Codable, Sendable {
    case original
}

public enum OCRRecognitionLevel: String, Codable, Sendable, CaseIterable {
    case fast
    case accurate
}

public enum OCRRecognitionEngine: String, Codable, Sendable, CaseIterable {
    case visionFast = "vision_fast"
    case visionAccurate = "vision_accurate"
}

public struct ProjectOCRRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let expectedRevision: Int?
    public let region: ImagePixelRect?
    public let recognitionLevel: OCRRecognitionLevel
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool
    public let minimumConfidence: Double

    public init(
        projectID: String,
        expectedRevision: Int? = nil,
        region: ImagePixelRect? = nil,
        recognitionLevel: OCRRecognitionLevel = .accurate,
        recognitionLanguages: [String] = [],
        usesLanguageCorrection: Bool = true,
        minimumConfidence: Double = 0
    ) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.region = region
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumConfidence = minimumConfidence
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case expectedRevision = "expected_revision"
        case region
        case recognitionLevel = "recognition_level"
        case recognitionLanguages = "recognition_languages"
        case usesLanguageCorrection = "uses_language_correction"
        case minimumConfidence = "minimum_confidence"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        expectedRevision = try container.decodeIfPresent(Int.self, forKey: .expectedRevision)
        region = try container.decodeIfPresent(ImagePixelRect.self, forKey: .region)
        recognitionLevel =
            try container.decodeIfPresent(OCRRecognitionLevel.self, forKey: .recognitionLevel)
            ?? .accurate
        recognitionLanguages =
            try container.decodeIfPresent([String].self, forKey: .recognitionLanguages)
            ?? []
        usesLanguageCorrection =
            try container.decodeIfPresent(Bool.self, forKey: .usesLanguageCorrection)
            ?? true
        minimumConfidence =
            try container.decodeIfPresent(Double.self, forKey: .minimumConfidence)
            ?? 0
    }
}

public struct OCRTextObservation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let confidence: Double
    public let language: String
    public let boundingBox: ImagePixelRect

    public init(
        id: String,
        text: String,
        confidence: Double,
        language: String = "und",
        boundingBox: ImagePixelRect
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.language = language
        self.boundingBox = boundingBox
    }
}

public struct ProjectOCRResult: Codable, Sendable, Equatable {
    public let projectID: String
    public let projectRevision: Int
    public let source: ProjectAnalysisSource
    public let analyzedRegion: ImagePixelRect
    public let recognitionLevel: OCRRecognitionLevel
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool
    public let recognitionEngine: OCRRecognitionEngine
    public let effectiveRecognitionLanguages: [String]
    public let detectedLanguages: [String]
    public let fullText: String
    public let observations: [OCRTextObservation]
    public let createdAt: Date

    public init(
        projectID: String,
        projectRevision: Int,
        source: ProjectAnalysisSource,
        analyzedRegion: ImagePixelRect,
        recognitionLevel: OCRRecognitionLevel,
        recognitionLanguages: [String],
        usesLanguageCorrection: Bool,
        recognitionEngine: OCRRecognitionEngine,
        effectiveRecognitionLanguages: [String],
        detectedLanguages: [String],
        fullText: String,
        observations: [OCRTextObservation],
        createdAt: Date
    ) {
        self.projectID = projectID
        self.projectRevision = projectRevision
        self.source = source
        self.analyzedRegion = analyzedRegion
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.recognitionEngine = recognitionEngine
        self.effectiveRecognitionLanguages = effectiveRecognitionLanguages
        self.detectedLanguages = detectedLanguages
        self.fullText = fullText
        self.observations = observations
        self.createdAt = createdAt
    }
}

public enum ColorSamplingMode: String, Codable, Sendable, CaseIterable {
    case point
    case region
}

public struct ProjectColorSampleRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let expectedRevision: Int?
    public let mode: ColorSamplingMode
    public let point: ImagePixelPoint?
    public let region: ImagePixelRect?

    public init(
        projectID: String,
        expectedRevision: Int? = nil,
        mode: ColorSamplingMode,
        point: ImagePixelPoint? = nil,
        region: ImagePixelRect? = nil
    ) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.mode = mode
        self.point = point
        self.region = region
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case expectedRevision = "expected_revision"
        case mode
        case point
        case region
    }
}

public struct SampledColor: Codable, Sendable, Equatable {
    public let rgba: RGBAColor
    public let hexRGB: String
    public let hexRGBA: String
    public let relativeLuminance: Double
    public let isDark: Bool

    public init(rgba: RGBAColor) {
        let normalized = RGBAColor(
            red: min(max(rgba.red, 0), 1),
            green: min(max(rgba.green, 0), 1),
            blue: min(max(rgba.blue, 0), 1),
            alpha: min(max(rgba.alpha, 0), 1)
        )
        self.rgba = normalized

        let red = Int((normalized.red * 255).rounded())
        let green = Int((normalized.green * 255).rounded())
        let blue = Int((normalized.blue * 255).rounded())
        let alpha = Int((normalized.alpha * 255).rounded())
        self.hexRGB = String(format: "#%02X%02X%02X", red, green, blue)
        self.hexRGBA = String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)

        func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance =
            0.2126 * linearized(normalized.red)
            + 0.7152 * linearized(normalized.green)
            + 0.0722 * linearized(normalized.blue)
        self.relativeLuminance = luminance
        self.isDark = luminance < 0.179
    }
}

public struct ProjectColorSampleResult: Codable, Sendable, Equatable {
    public let projectID: String
    public let projectRevision: Int
    public let source: ProjectAnalysisSource
    public let mode: ColorSamplingMode
    public let point: ImagePixelPoint?
    public let region: ImagePixelRect?
    public let primaryColor: SampledColor
    public let averageColor: SampledColor?
    public let centerColor: SampledColor?
    public let dominantColor: SampledColor?
    public let sampledPixelCount: Int
    public let createdAt: Date

    public init(
        projectID: String,
        projectRevision: Int,
        source: ProjectAnalysisSource,
        mode: ColorSamplingMode,
        point: ImagePixelPoint?,
        region: ImagePixelRect?,
        primaryColor: SampledColor,
        averageColor: SampledColor?,
        centerColor: SampledColor?,
        dominantColor: SampledColor?,
        sampledPixelCount: Int,
        createdAt: Date
    ) {
        self.projectID = projectID
        self.projectRevision = projectRevision
        self.source = source
        self.mode = mode
        self.point = point
        self.region = region
        self.primaryColor = primaryColor
        self.averageColor = averageColor
        self.centerColor = centerColor
        self.dominantColor = dominantColor
        self.sampledPixelCount = sampledPixelCount
        self.createdAt = createdAt
    }
}
