import Foundation
import MupawCore

enum L10n {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static func permissionStatus(_ status: PermissionStatus) -> String {
        switch status {
        case .authorized:
            return string("permission.status.authorized")
        case .denied:
            return string("permission.status.denied")
        case .notDetermined:
            return string("permission.status.not_determined")
        case .restricted:
            return string("permission.status.restricted")
        case .unavailable:
            return string("permission.status.unavailable")
        }
    }

    static func captureMode(_ mode: ScreenshotCaptureMode) -> String {
        switch mode {
        case .fullScreen:
            return string("capture.mode.full_screen")
        case .window:
            return string("capture.mode.window")
        case .region:
            return string("capture.mode.region")
        }
    }

    static func sourceKind(_ kind: CaptureSourceKind) -> String {
        switch kind {
        case .display:
            return string("capture.mode.full_screen")
        case .window:
            return string("capture.mode.window")
        case .region:
            return string("capture.mode.region")
        }
    }

    static func ocrEngine(_ engine: OCRRecognitionEngine) -> String {
        switch engine {
        case .visionFast:
            return string("editor.ocr.engine.vision_fast")
        case .visionAccurate:
            return string("editor.ocr.engine.vision_accurate")
        }
    }

    static func ocrLanguage(_ identifier: String) -> String {
        guard identifier != "und" else {
            return string("editor.ocr.language.undetermined")
        }
        return Locale.current.localizedString(forLanguageCode: identifier) ?? identifier
    }

    static func editKind(_ kind: ScreenshotEditKind) -> String {
        switch kind {
        case .arrow:
            return string("editor.kind.arrow")
        case .text:
            return string("editor.kind.text")
        case .mosaic:
            return string("editor.kind.mosaic")
        }
    }
}
