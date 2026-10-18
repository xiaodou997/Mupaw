import Foundation

public enum MupawConstants {
    public static let appName = "Mupaw"
    public static let appBundleIdentifier = "com.xiaodou.mupaw"
    public static let appVersion = "0.1.0-dev"
    public static let rpcProtocolVersion = 1
    public static let maximumRPCFrameBytes = 4 * 1024 * 1024
    public static let maximumRPCIdentifierUTF8Bytes = 256
    public static let maximumRPCMethodUTF8Bytes = 128
    public static let rpcSocketTimeoutSeconds = 30
    public static let previewMaximumDimension = 1_280
    public static let maximumScreenshotPixelCount = 120_000_000
    public static let minimumRegionPointDimension = 2.0
    public static let screenshotProjectSchemaVersion = 1
    public static let maximumProjectObjects = 500
    public static let maximumProjectCommandsPerBatch = 1_000
    public static let maximumProjectHistoryDepth = 50
    public static let maximumProjectTitleUTF8Bytes = 256
    public static let maximumProjectSourceArtifactIDUTF8Bytes = 256
    public static let maximumTextEditUTF8Bytes = 4_096
    public static let minimumEditorObjectSize = 2.0
    public static let maximumEditorLineWidth = 128.0
    public static let minimumEditorFontSize = 6.0
    public static let maximumEditorFontSize = 512.0
    public static let minimumMosaicBlockSize = 2.0
    public static let maximumMosaicBlockSize = 256.0
    public static let maximumStylePadding = 2_048.0
    public static let maximumStyleCornerRadius = 512.0
    public static let maximumStyleShadowBlurRadius = 256.0
    public static let maximumStyleShadowOffset = 512.0
    public static let maximumStyleGradientAngleMagnitude = 3_600.0
    public static let maximumOCRLanguages = 8
    public static let maximumOCRLanguageTagUTF8Bytes = 64
    public static let maximumOCRObservations = 512
    public static let maximumOCRObservationTextUTF8Bytes = 4_096
    public static let maximumOCRCombinedTextUTF8Bytes = 256 * 1_024
    public static let maximumOCRInputDimension = 4_096
    public static let minimumOCRLanguageIdentificationConfidence = 0.70
    public static let minimumOCRASCIILettersForLanguageIdentification = 8
    public static let ocrHelperTimeoutSeconds = 120.0
    public static let ocrRPCTimeoutSeconds = 150.0
    public static let maximumColorSampleDimension = 256
    public static let maximumColorSamplePixels = 65_536

}
