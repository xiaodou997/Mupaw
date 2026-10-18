import MupawCore
import SwiftUI

struct ScreenshotStyleEditorSheet: View {
    @Bindable var model: AppModel
    let project: ScreenshotProjectState

    @Environment(\.dismiss) private var dismiss
    @State private var styleEnabled: Bool
    @State private var draft: ScreenshotVisualStyle

    init(model: AppModel, project: ScreenshotProjectState) {
        self.model = model
        self.project = project
        let initial = project.content.visualStyle ?? ScreenshotStylePreset.cleanWhite.style!
        _styleEnabled = State(initialValue: project.content.visualStyle != nil)
        _draft = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    presetSection
                    Divider()
                    canvasSection
                    Divider()
                    backgroundSection
                    Divider()
                    cardSection
                    Divider()
                    shadowSection
                }
                .padding(20)
            }
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)

            Divider()

            VStack(spacing: 18) {
                Text(L10n.string("editor.style.preview"))
                    .font(.headline)
                StylePreviewCard(style: styleEnabled ? draft : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)

                HStack {
                    Button(L10n.string("common.cancel")) {
                        dismiss()
                    }
                    Spacer()
                    Button(L10n.string("editor.style.clear"), role: .destructive) {
                        Task {
                            await model.clearVisualStyle()
                            dismiss()
                        }
                    }
                    .disabled(model.isBusy || project.content.visualStyle == nil)
                    Button(L10n.string("editor.style.apply")) {
                        let enabled = styleEnabled
                        let value = draft
                        Task {
                            if enabled {
                                await model.setVisualStyle(value)
                            } else {
                                await model.clearVisualStyle()
                            }
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .frame(minWidth: 440)
        }
        .frame(minWidth: 860, minHeight: 680)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("editor.style.presets"))
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(ScreenshotStylePreset.allCases, id: \.self) { preset in
                    Button {
                        if let style = preset.style {
                            draft = style
                            styleEnabled = true
                        } else {
                            styleEnabled = false
                        }
                    } label: {
                        VStack(spacing: 6) {
                            StylePresetSwatch(preset: preset)
                                .frame(height: 44)
                            Text(L10n.stylePreset(preset))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle(L10n.string("editor.style.enabled"), isOn: $styleEnabled)
        }
    }

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("editor.style.canvas"))
                .font(.headline)
            Picker(L10n.string("editor.style.aspect"), selection: aspectBinding) {
                ForEach(ScreenshotCanvasAspect.allCases, id: \.self) { aspect in
                    Text(L10n.canvasAspect(aspect)).tag(aspect)
                }
            }
            slider(
                title: L10n.string("editor.style.padding"),
                value: paddingBinding,
                range: 0...MupawConstants.maximumStylePadding,
                step: 4,
                suffix: "px"
            )
        }
        .disabled(!styleEnabled)
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("editor.style.background"))
                .font(.headline)
            Picker(L10n.string("editor.style.background_mode"), selection: backgroundModeBinding) {
                ForEach(ScreenshotBackgroundMode.allCases, id: \.self) { mode in
                    Text(L10n.backgroundMode(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            ColorPicker(
                L10n.string(
                    draft.background.mode == .solid
                        ? "editor.style.background_color"
                        : "editor.style.gradient_start"
                ),
                selection: startColorBinding,
                supportsOpacity: true
            )
            if draft.background.mode == .linearGradient {
                ColorPicker(
                    L10n.string("editor.style.gradient_end"),
                    selection: endColorBinding,
                    supportsOpacity: true
                )
                slider(
                    title: L10n.string("editor.style.gradient_angle"),
                    value: gradientAngleBinding,
                    range: -180...180,
                    step: 1,
                    suffix: "°"
                )
            }
        }
        .disabled(!styleEnabled)
    }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("editor.style.card"))
                .font(.headline)
            slider(
                title: L10n.string("editor.style.corner_radius"),
                value: cornerRadiusBinding,
                range: 0...MupawConstants.maximumStyleCornerRadius,
                step: 2,
                suffix: "px"
            )
        }
        .disabled(!styleEnabled)
    }

    private var shadowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("editor.style.shadow"))
                .font(.headline)
            Toggle(L10n.string("editor.style.shadow_enabled"), isOn: shadowEnabledBinding)
            Group {
                ColorPicker(
                    L10n.string("editor.style.shadow_color"),
                    selection: shadowColorBinding,
                    supportsOpacity: true
                )
                slider(
                    title: L10n.string("editor.style.shadow_blur"),
                    value: shadowBlurBinding,
                    range: 0...MupawConstants.maximumStyleShadowBlurRadius,
                    step: 2,
                    suffix: "px"
                )
                slider(
                    title: L10n.string("editor.style.shadow_offset_x"),
                    value: shadowOffsetXBinding,
                    range: (-MupawConstants.maximumStyleShadowOffset)...MupawConstants.maximumStyleShadowOffset,
                    step: 2,
                    suffix: "px"
                )
                slider(
                    title: L10n.string("editor.style.shadow_offset_y"),
                    value: shadowOffsetYBinding,
                    range: (-MupawConstants.maximumStyleShadowOffset)...MupawConstants.maximumStyleShadowOffset,
                    step: 2,
                    suffix: "px"
                )
            }
            .disabled(!draft.shadow.isEnabled)
        }
        .disabled(!styleEnabled)
    }

    private func slider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private var aspectBinding: Binding<ScreenshotCanvasAspect> {
        Binding(
            get: { draft.canvasAspect },
            set: { draft.canvasAspect = $0 }
        )
    }

    private var paddingBinding: Binding<Double> {
        Binding(get: { draft.padding }, set: { draft.padding = $0 })
    }

    private var backgroundModeBinding: Binding<ScreenshotBackgroundMode> {
        Binding(get: { draft.background.mode }, set: { draft.background.mode = $0 })
    }

    private var startColorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: draft.background.startColor) },
            set: { draft.background.startColor = $0.rgba }
        )
    }

    private var endColorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: draft.background.endColor) },
            set: { draft.background.endColor = $0.rgba }
        )
    }

    private var gradientAngleBinding: Binding<Double> {
        Binding(get: { draft.background.angleDegrees }, set: { draft.background.angleDegrees = $0 })
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(get: { draft.cornerRadius }, set: { draft.cornerRadius = $0 })
    }

    private var shadowEnabledBinding: Binding<Bool> {
        Binding(get: { draft.shadow.isEnabled }, set: { draft.shadow.isEnabled = $0 })
    }

    private var shadowColorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: draft.shadow.color) },
            set: { draft.shadow.color = $0.rgba }
        )
    }

    private var shadowBlurBinding: Binding<Double> {
        Binding(get: { draft.shadow.blurRadius }, set: { draft.shadow.blurRadius = $0 })
    }

    private var shadowOffsetXBinding: Binding<Double> {
        Binding(get: { draft.shadow.offsetX }, set: { draft.shadow.offsetX = $0 })
    }

    private var shadowOffsetYBinding: Binding<Double> {
        Binding(get: { draft.shadow.offsetY }, set: { draft.shadow.offsetY = $0 })
    }
}

private struct StylePreviewCard: View {
    let style: ScreenshotVisualStyle?

    var body: some View {
        GeometryReader { proxy in
            let padding = min(80, max(18, CGFloat(style?.padding ?? 0) * 0.35))
            ZStack {
                background
                RoundedRectangle(cornerRadius: CGFloat(style?.cornerRadius ?? 0) * 0.35)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.96, green: 0.97, blue: 0.99),
                                Color(red: 0.84, green: 0.88, blue: 0.95),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        VStack(spacing: 10) {
                            HStack(spacing: 7) {
                                Circle().fill(.red.opacity(0.8)).frame(width: 9, height: 9)
                                Circle().fill(.yellow.opacity(0.8)).frame(width: 9, height: 9)
                                Circle().fill(.green.opacity(0.8)).frame(width: 9, height: 9)
                                Spacer()
                            }
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(0.75))
                            HStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(.white.opacity(0.58))
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(.white.opacity(0.42))
                            }
                            .frame(height: 54)
                        }
                        .padding(18)
                    }
                    .shadow(
                        color: style.map { Color(rgba: $0.shadow.color) }
                            ?? .clear,
                        radius: style?.shadow.isEnabled == true
                            ? CGFloat(style?.shadow.blurRadius ?? 0) * 0.25
                            : 0,
                        x: style?.shadow.isEnabled == true
                            ? CGFloat(style?.shadow.offsetX ?? 0) * 0.25
                            : 0,
                        y: style?.shadow.isEnabled == true
                            ? CGFloat(style?.shadow.offsetY ?? 0) * 0.25
                            : 0
                    )
                    .padding(padding)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator, lineWidth: 1))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private var background: some View {
        if let style {
            switch style.background.mode {
            case .solid:
                Color(rgba: style.background.startColor)
            case .linearGradient:
                LinearGradient(
                    colors: [
                        Color(rgba: style.background.startColor),
                        Color(rgba: style.background.endColor),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

private struct StylePresetSwatch: View {
    let preset: ScreenshotStylePreset

    var body: some View {
        ZStack {
            if let style = preset.style {
                switch style.background.mode {
                case .solid:
                    Color(rgba: style.background.startColor)
                case .linearGradient:
                    LinearGradient(
                        colors: [
                            Color(rgba: style.background.startColor),
                            Color(rgba: style.background.endColor),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
            } else {
                Color(nsColor: .windowBackgroundColor)
                Image(systemName: "nosign")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
