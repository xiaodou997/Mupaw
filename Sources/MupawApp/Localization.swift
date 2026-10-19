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

    static func stylePreset(_ preset: ScreenshotStylePreset) -> String {
        switch preset {
        case .none:
            return string("editor.style.preset.none")
        case .cleanWhite:
            return string("editor.style.preset.clean_white")
        case .softGray:
            return string("editor.style.preset.soft_gray")
        case .ocean:
            return string("editor.style.preset.ocean")
        case .sunset:
            return string("editor.style.preset.sunset")
        case .midnight:
            return string("editor.style.preset.midnight")
        }
    }

    static func canvasAspect(_ aspect: ScreenshotCanvasAspect) -> String {
        switch aspect {
        case .automatic:
            return string("editor.style.aspect.automatic")
        case .square:
            return string("editor.style.aspect.square")
        case .landscapeFourThree:
            return string("editor.style.aspect.landscape_4_3")
        case .landscapeSixteenNine:
            return string("editor.style.aspect.landscape_16_9")
        case .portraitThreeFour:
            return string("editor.style.aspect.portrait_3_4")
        case .portraitNineSixteen:
            return string("editor.style.aspect.portrait_9_16")
        }
    }

    static func backgroundMode(_ mode: ScreenshotBackgroundMode) -> String {
        switch mode {
        case .solid:
            return string("editor.style.background.solid")
        case .linearGradient:
            return string("editor.style.background.gradient")
        }
    }

    static func recordingQuality(_ quality: RecordingVideoQuality) -> String {
        switch quality {
        case .standard:
            return string("recording.quality.standard")
        case .high:
            return string("recording.quality.high")
        }
    }

    static func recordingPhase(_ phase: RecordingPhase) -> String {
        switch phase {
        case .starting:
            return string("recording.phase.starting")
        case .recording:
            return string("recording.phase.recording")
        case .stopping:
            return string("recording.phase.stopping")
        case .completed:
            return string("recording.phase.completed")
        case .failed:
            return string("recording.phase.failed")
        case .cancelled:
            return string("recording.phase.cancelled")
        }
    }

    static func recordingAudioState(_ state: RecordingAudioState) -> String {
        switch state {
        case .disabled:
            return string("recording.audio.state.disabled")
        case .waiting:
            return string("recording.audio.state.waiting")
        case .capturing:
            return string("recording.audio.state.capturing")
        case .completed:
            return string("recording.audio.state.completed")
        case .failed:
            return string("recording.audio.state.failed")
        case .cancelled:
            return string("recording.audio.state.cancelled")
        }
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
