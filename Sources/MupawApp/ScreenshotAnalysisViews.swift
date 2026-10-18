import AppKit
import MupawCore
import SwiftUI

struct ScreenshotAnalysisOverlay: View {
    let project: ScreenshotProjectState
    let mapping: EditorCanvasMapping
    let ocrResult: ProjectOCRResult?
    let selectedOCRObservationID: String?
    let colorSample: ProjectColorSampleResult?
    let isPointSampling: Bool
    let isBusy: Bool
    let onSelectOCR: (String?) -> Void
    let onSamplePoint: (ImagePixelPoint) -> Void

    var body: some View {
        ZStack {
            if let result = validOCRResult {
                ForEach(result.observations) { observation in
                    if let visibleBox = observation.boundingBox.intersection(project.visibleBounds) {
                        let frame = mapping.viewRect(for: visibleBox)
                        Rectangle()
                            .fill(
                                selectedOCRObservationID == observation.id
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.orange.opacity(0.08)
                            )
                            .overlay {
                                Rectangle()
                                    .stroke(
                                        selectedOCRObservationID == observation.id
                                            ? Color.accentColor
                                            : Color.orange,
                                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                                    )
                            }
                            .frame(width: max(2, frame.width), height: max(2, frame.height))
                            .position(x: frame.midX, y: frame.midY)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !isPointSampling else { return }
                                onSelectOCR(observation.id)
                            }
                    }
                }
            }

            if let sample = validColorSample {
                switch sample.mode {
                case .point:
                    if let point = sample.point,
                        project.visibleBounds.contains(point)
                    {
                        let viewPoint = mapping.viewPoint(for: point)
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .overlay(Circle().stroke(Color(rgba: sample.primaryColor.rgba), lineWidth: 2))
                            .frame(width: 22, height: 22)
                            .position(viewPoint)
                            .allowsHitTesting(false)
                    }
                case .region:
                    if let region = sample.region,
                        let visibleRegion = region.intersection(project.visibleBounds)
                    {
                        let frame = mapping.viewRect(for: visibleRegion)
                        Rectangle()
                            .stroke(.white, lineWidth: 4)
                            .overlay(
                                Rectangle()
                                    .stroke(
                                        Color(rgba: sample.primaryColor.rgba),
                                        style: StrokeStyle(lineWidth: 2, dash: [7, 4])
                                    )
                            )
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }
                }
            }

            if isPointSampling {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: mapping.imageFrame.width, height: mapping.imageFrame.height)
                    .position(x: mapping.imageFrame.midX, y: mapping.imageFrame.midY)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard !isBusy,
                                    let point = mapping.pixelPoint(for: value.location)
                                else {
                                    return
                                }
                                onSamplePoint(point)
                            }
                    )

                Text(L10n.string("editor.analysis.point_hint"))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .position(
                        x: mapping.imageFrame.midX,
                        y: max(mapping.imageFrame.minY + 22, 22)
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var validOCRResult: ProjectOCRResult? {
        guard let ocrResult,
            ocrResult.projectID == project.id,
            ocrResult.projectRevision == project.revision
        else {
            return nil
        }
        return ocrResult
    }

    private var validColorSample: ProjectColorSampleResult? {
        guard let colorSample,
            colorSample.projectID == project.id,
            colorSample.projectRevision == project.revision
        else {
            return nil
        }
        return colorSample
    }
}

struct OCRInspectorSection: View {
    @Bindable var model: AppModel
    let project: ScreenshotProjectState

    var body: some View {
        Divider()
        HStack {
            Text(L10n.string("editor.ocr.title"))
                .font(.headline)
            Spacer()
            if let result = validResult {
                Text(L10n.format("editor.ocr.lines.format", result.observations.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }

        if let result = validResult {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    L10n.format(
                        "editor.ocr.engine.format",
                        L10n.ocrEngine(result.recognitionEngine)
                    )
                )
                if !result.effectiveRecognitionLanguages.isEmpty {
                    Text(
                        L10n.format(
                            "editor.ocr.languages.format",
                            result.effectiveRecognitionLanguages.joined(separator: ", ")
                        )
                    )
                }
                if !result.detectedLanguages.isEmpty {
                    Text(
                        L10n.format(
                            "editor.ocr.detected_languages.format",
                            result.detectedLanguages.map(L10n.ocrLanguage).joined(separator: ", ")
                        )
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(L10n.string("editor.ocr.copy_all")) {
                    model.copyOCRTextToPasteboard()
                }
                .disabled(result.fullText.isEmpty)
                Spacer()
                Button(L10n.string("editor.ocr.clear"), role: .destructive) {
                    model.clearOCRResult()
                }
            }
            .controlSize(.small)

            if result.observations.isEmpty {
                Text(L10n.string("editor.ocr.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(result.observations.prefix(80)) { observation in
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                model.selectOCRObservation(observation.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(observation.text)
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    HStack {
                                        Text(
                                            L10n.format(
                                                "editor.ocr.confidence.format",
                                                observation.confidence * 100
                                            )
                                        )
                                        Text(
                                            L10n.format(
                                                "editor.ocr.language.format",
                                                L10n.ocrLanguage(observation.language)
                                            )
                                        )
                                        Spacer()
                                        Text(
                                            "\(Int(observation.boundingBox.minX)), \(Int(observation.boundingBox.minY)) · \(Int(observation.boundingBox.width)) × \(Int(observation.boundingBox.height))"
                                        )
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                .padding(7)
                                .background(
                                    model.selectedOCRObservationID == observation.id
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                model.copyOCRObservationToPasteboard(observation.id)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.string("editor.ocr.copy_line"))
                            .accessibilityLabel(L10n.string("editor.ocr.copy_line"))
                        }
                    }
                }
            }
        } else {
            Text(L10n.string("editor.ocr.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var validResult: ProjectOCRResult? {
        guard let result = model.lastOCRResult,
            result.projectID == project.id,
            result.projectRevision == project.revision
        else {
            return nil
        }
        return result
    }
}

struct ColorInspectorSection: View {
    @Bindable var model: AppModel
    let project: ScreenshotProjectState

    var body: some View {
        Divider()
        HStack {
            Text(L10n.string("editor.color.title"))
                .font(.headline)
            Spacer()
            if validResult != nil {
                Button(L10n.string("editor.color.clear"), role: .destructive) {
                    model.clearColorSample()
                }
                .controlSize(.small)
            }
        }

        if let result = validResult {
            if result.mode == .point, let point = result.point {
                Text(
                    L10n.format(
                        "editor.color.point.format",
                        Int(point.x),
                        Int(point.y)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let region = result.region {
                Text(
                    L10n.format(
                        "editor.color.region.format",
                        Int(region.minX),
                        Int(region.minY),
                        Int(region.width),
                        Int(region.height)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ColorSampleRow(
                title: L10n.string("editor.color.primary"),
                color: result.primaryColor
            )
            if let average = result.averageColor {
                ColorSampleRow(
                    title: L10n.string("editor.color.average"),
                    color: average
                )
            }
            if let center = result.centerColor {
                ColorSampleRow(
                    title: L10n.string("editor.color.center"),
                    color: center
                )
            }
            if let dominant = result.dominantColor {
                ColorSampleRow(
                    title: L10n.string("editor.color.dominant"),
                    color: dominant
                )
            }
            Text(L10n.format("editor.color.samples.format", result.sampledPixelCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(L10n.string("editor.color.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var validResult: ProjectColorSampleResult? {
        guard let result = model.lastColorSample,
            result.projectID == project.id,
            result.projectRevision == project.revision
        else {
            return nil
        }
        return result
    }
}

private struct ColorSampleRow: View {
    let title: String
    let color: SampledColor

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(rgba: color.rgba))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator, lineWidth: 1))
                .frame(width: 34, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(color.hexRGBA)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(
                    L10n.format(
                        "editor.color.luminance.format",
                        color.relativeLuminance,
                        L10n.string(
                            color.isDark
                                ? "editor.color.classification.dark"
                                : "editor.color.classification.light"
                        )
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ColorRegionSamplerSheet: View {
    @Bindable var model: AppModel
    let project: ScreenshotProjectState
    let originalImage: NSImage

    @Environment(\.dismiss) private var dismiss
    @State private var draftRect: ImagePixelRect
    @GestureState private var moveTranslation: CGSize = .zero
    @GestureState private var resizeTranslation: CGSize = .zero

    init(model: AppModel, project: ScreenshotProjectState, originalImage: NSImage) {
        self.model = model
        self.project = project
        self.originalImage = originalImage
        _draftRect = State(initialValue: project.visibleBounds)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.string("editor.color.region.title"))
                    .font(.title2.bold())
                Spacer()
                Text("\(Int(draftRect.standardized.width)) × \(Int(draftRect.standardized.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let mapping = EditorCanvasMapping(
                    containerSize: proxy.size,
                    visibleBounds: project.originalBounds
                )
                let base = mapping.viewRect(for: draftRect)
                let displayed = base.offsetBy(
                    dx: moveTranslation.width,
                    dy: moveTranslation.height
                )

                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Image(nsImage: originalImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: mapping.imageFrame.width, height: mapping.imageFrame.height)
                        .position(x: mapping.imageFrame.midX, y: mapping.imageFrame.midY)

                    Rectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .background(Color.accentColor.opacity(0.08))
                        .frame(width: displayed.width, height: displayed.height)
                        .position(x: displayed.midX, y: displayed.midY)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .updating($moveTranslation) { value, state, _ in
                                    state = value.translation
                                }
                                .onEnded { value in
                                    let delta = mapping.pixelDelta(for: value.translation)
                                    draftRect = draftRect.translated(
                                        dx: delta.width,
                                        dy: delta.height
                                    ).clamped(to: project.originalBounds, minimumSize: 1)
                                }
                        )

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .position(
                            x: displayed.maxX + resizeTranslation.width,
                            y: displayed.maxY + resizeTranslation.height
                        )
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .updating($resizeTranslation) { value, state, _ in
                                    state = value.translation
                                }
                                .onEnded { value in
                                    let delta = mapping.pixelDelta(for: value.translation)
                                    let old = draftRect.standardized
                                    draftRect = ImagePixelRect(
                                        x: old.minX,
                                        y: old.minY,
                                        width: max(1, old.width + delta.width),
                                        height: max(1, old.height + delta.height)
                                    ).clamped(to: project.originalBounds, minimumSize: 1)
                                }
                        )
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel")) {
                    dismiss()
                }
                Button(L10n.string("editor.color.region.apply")) {
                    let region = draftRect
                    Task { await model.sampleColor(in: region) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
        .padding(18)
        .frame(minWidth: 780, minHeight: 580)
    }
}
