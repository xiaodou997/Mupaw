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

}
