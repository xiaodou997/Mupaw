import AppKit
import MupawCore
import SwiftUI

struct ScreenshotEditorView: View {
    @Bindable var model: AppModel
    @State private var showsCropEditor = false

    var body: some View {
        if let project = model.activeProject,
            let preview = model.activeProjectPreview,
            let image = preview.preview.nsImage
        {
            VStack(spacing: 0) {
                toolbar(project: project)
                Divider()
                HSplitView {
                    editorCanvas(project: project, preview: preview, image: image)
                        .frame(minWidth: 480)
                    inspector(project: project)
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
                }
                Divider()
                footer(project: project, preview: preview)
            }
            .sheet(isPresented: $showsCropEditor) {
                if let original = NSImage(contentsOf: project.originalFileURL) {
                    CropEditorSheet(model: model, project: project, originalImage: original)
                } else {
                    ContentUnavailableView(
                        L10n.string("editor.crop.unavailable.title"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(L10n.string("editor.crop.unavailable.description"))
                    )
                    .frame(width: 520, height: 320)
                }
            }
        } else {
            ContentUnavailableView(
                L10n.string("editor.empty.title"),
                systemImage: "pencil.and.outline",
                description: Text(L10n.string("editor.empty.description"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toolbar(project: ScreenshotProjectState) -> some View {
        HStack(spacing: 8) {
            toolButton(
                L10n.string("editor.tool.arrow"),
                systemImage: "arrow.up.right",
                action: { Task { await model.addArrowEdit() } }
            )
            toolButton(
                L10n.string("editor.tool.text"),
                systemImage: "textformat",
                action: { Task { await model.addTextEdit() } }
            )
            toolButton(
                L10n.string("editor.tool.mosaic"),
                systemImage: "square.grid.3x3.fill",
                action: { Task { await model.addMosaicEdit() } }
            )
            toolButton(
                L10n.string("editor.tool.crop"),
                systemImage: "crop",
                action: { showsCropEditor = true }
            )

            Divider().frame(height: 24)

            Button {
                Task { await model.undoActiveProject() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help(L10n.string("editor.action.undo"))
            .accessibilityLabel(L10n.string("editor.action.undo"))
            .disabled(model.isBusy || !project.canUndo)

            Button {
                Task { await model.redoActiveProject() }
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help(L10n.string("editor.action.redo"))
            .accessibilityLabel(L10n.string("editor.action.redo"))
            .disabled(model.isBusy || !project.canRedo)

            Button(role: .destructive) {
                Task { await model.deleteSelectedEditObject() }
            } label: {
                Image(systemName: "trash")
            }
            .help(L10n.string("editor.action.delete"))
            .accessibilityLabel(L10n.string("editor.action.delete"))
            .disabled(model.isBusy || model.selectedEditObject == nil)

            Button(role: .destructive) {
                Task { await model.resetActiveProject() }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help(L10n.string("editor.action.reset"))
            .accessibilityLabel(L10n.string("editor.action.reset"))
            .disabled(model.isBusy || (project.content.objects.isEmpty && project.content.cropRect == nil))

            Spacer()

            Text(L10n.format("editor.revision.format", project.revision))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                Task { await model.exportActiveProject() }
            } label: {
                Label(L10n.string("editor.action.export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toolButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .help(title)
        .accessibilityLabel(title)
        .disabled(model.isBusy)
    }

    private func editorCanvas(
        project: ScreenshotProjectState,
        preview: ProjectPreviewResult,
        image: NSImage
    ) -> some View {
        GeometryReader { proxy in
            let mapping = EditorCanvasMapping(
                containerSize: proxy.size,
                visibleBounds: project.visibleBounds
            )
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: mapping.imageFrame.width, height: mapping.imageFrame.height)
                    .position(x: mapping.imageFrame.midX, y: mapping.imageFrame.midY)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: mapping.imageFrame.width, height: mapping.imageFrame.height)
                    .position(x: mapping.imageFrame.midX, y: mapping.imageFrame.midY)
                    .accessibilityLabel(L10n.string("editor.canvas.preview"))

                ForEach(project.content.objects) { object in
                    if object.bounds.intersection(project.visibleBounds) != nil {
                        ScreenshotObjectOverlay(
                            object: object,
                            project: project,
                            mapping: mapping,
                            isSelected: model.selectedEditObjectID == object.id,
                            isDisabled: model.isBusy,
                            onSelect: { model.selectEditObject(object.id) },
                            onCommit: { updated in
                                Task { await model.updateEditObject(updated) }
                            }
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectEditObject(nil)
            }
        }
        .padding(12)
    }

    private func inspector(project: ScreenshotProjectState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string("editor.inspector.title"))
                    .font(.headline)

                if let object = model.selectedEditObject {
                    EditObjectInspector(
                        object: object,
                        isBusy: model.isBusy,
                        onApply: { updated in
                            Task { await model.updateEditObject(updated) }
                        }
                    )
                    .id("\(object.id)-\(project.revision)")
                } else {
                    Text(L10n.string("editor.inspector.no_selection"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(L10n.string("editor.layers.title"))
                    .font(.headline)
                if project.content.objects.isEmpty {
                    Text(L10n.string("editor.layers.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(project.content.objects.reversed()) { object in
                            Button {
                                model.selectEditObject(object.id)
                            } label: {
                                HStack {
                                    Image(systemName: icon(for: object.kind))
                                    Text(L10n.editKind(object.kind))
                                    Spacer()
                                    Text(String(object.id.prefix(6)))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    model.selectedEditObjectID == object.id
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let export = model.lastProjectExport,
                    export.projectID == project.id
                {
                    Divider()
                    Text(L10n.string("editor.export.latest"))
                        .font(.headline)
                    Text(export.fileURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Text(
                        "\(export.pixelWidth) × \(export.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(export.byteCount), countStyle: .file))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func footer(
        project: ScreenshotProjectState,
        preview: ProjectPreviewResult
    ) -> some View {
        HStack(spacing: 12) {
            Label(project.title, systemImage: "photo")
            Text("\(preview.pixelWidth) × \(preview.pixelHeight)")
            Text(L10n.format("editor.objects.format", project.content.objects.count))
            if project.content.cropRect != nil {
                Label(L10n.string("editor.crop.active"), systemImage: "crop")
            }
            Spacer()
            Text(project.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func icon(for kind: ScreenshotEditKind) -> String {
        switch kind {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

private struct ScreenshotObjectOverlay: View {
    let object: ScreenshotEditObject
    let project: ScreenshotProjectState
    let mapping: EditorCanvasMapping
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    let onCommit: (ScreenshotEditObject) -> Void

    @GestureState private var moveTranslation: CGSize = .zero
    @GestureState private var resizeTranslation: CGSize = .zero
    @GestureState private var startTranslation: CGSize = .zero
    @GestureState private var endTranslation: CGSize = .zero

    var body: some View {
        let baseBounds = visibleHitBounds
        let translated = CGSize(
            width: moveTranslation.width,
            height: moveTranslation.height
        )
        let displayed = baseBounds.offsetBy(dx: translated.width, dy: translated.height)

        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: displayed.width, height: displayed.height)
                .position(x: displayed.midX, y: displayed.midY)
                .overlay {
                    if isSelected {
                        Rectangle()
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: displayed.width, height: displayed.height)
                            .position(x: displayed.midX, y: displayed.midY)
                            .allowsHitTesting(false)
                    }
                }
                .onTapGesture(perform: onSelect)
                .gesture(moveGesture)

            if isSelected {
                switch object {
                case .arrow(let arrow):
                    startEndpointHandle(
                        at: mapping.viewPoint(for: arrow.start)
                    )
                    endEndpointHandle(
                        at: mapping.viewPoint(for: arrow.end)
                    )
                case .text, .mosaic:
                    resizeHandle(at: CGPoint(x: displayed.maxX, y: displayed.maxY))
                }
            }
        }
        .allowsHitTesting(!isDisabled)
    }

    private var visibleHitBounds: CGRect {
        let rect = mapping.viewRect(for: object.bounds)
        let minimum: CGFloat = 24
        return CGRect(
            x: rect.midX - max(rect.width, minimum) / 2,
            y: rect.midY - max(rect.height, minimum) / 2,
            width: max(rect.width, minimum),
            height: max(rect.height, minimum)
        )
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($moveTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                onSelect()
                let delta = mapping.pixelDelta(for: value.translation)
                onCommit(clamp(object.translated(dx: delta.width, dy: delta.height)))
            }
    }

    private func startEndpointHandle(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .position(
                x: point.x + startTranslation.width,
                y: point.y + startTranslation.height
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($startTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        updateArrowEndpoint(isStart: true, translation: value.translation)
                    }
            )
    }

    private func endEndpointHandle(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .position(
                x: point.x + endTranslation.width,
                y: point.y + endTranslation.height
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($endTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        updateArrowEndpoint(isStart: false, translation: value.translation)
                    }
            )
    }

    private func updateArrowEndpoint(isStart: Bool, translation: CGSize) {
        guard case .arrow(let arrow) = object else { return }
        let delta = mapping.pixelDelta(for: translation)
        let bounds = project.originalBounds.standardized
        let original = isStart ? arrow.start : arrow.end
        let point = ImagePixelPoint(
            x: min(max(original.x + delta.width, bounds.minX), bounds.maxX),
            y: min(max(original.y + delta.height, bounds.minY), bounds.maxY)
        )
        let updated = ArrowEdit(
            id: arrow.id,
            start: isStart ? point : arrow.start,
            end: isStart ? arrow.end : point,
            color: arrow.color,
            lineWidth: arrow.lineWidth
        )
        onCommit(.arrow(updated))
    }

    private func resizeHandle(at point: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .position(
                x: point.x + resizeTranslation.width,
                y: point.y + resizeTranslation.height
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($resizeTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let delta = mapping.pixelDelta(for: value.translation)
                        let old = object.bounds.standardized
                        let proposed = ImagePixelRect(
                            x: old.minX,
                            y: old.minY,
                            width: max(MupawConstants.minimumEditorObjectSize, old.width + delta.width),
                            height: max(MupawConstants.minimumEditorObjectSize, old.height + delta.height)
                        ).clamped(
                            to: project.originalBounds,
                            minimumSize: MupawConstants.minimumEditorObjectSize
                        )
                        onCommit(object.replacingBounds(proposed))
                    }
            )
    }

    private func clamp(_ value: ScreenshotEditObject) -> ScreenshotEditObject {
        let bounds = project.originalBounds.standardized
        switch value {
        case .arrow(let arrow):
            let start = ImagePixelPoint(
                x: min(max(arrow.start.x, bounds.minX), bounds.maxX),
                y: min(max(arrow.start.y, bounds.minY), bounds.maxY)
            )
            let end = ImagePixelPoint(
                x: min(max(arrow.end.x, bounds.minX), bounds.maxX),
                y: min(max(arrow.end.y, bounds.minY), bounds.maxY)
            )
            return .arrow(
                ArrowEdit(
                    id: arrow.id,
                    start: start,
                    end: end,
                    color: arrow.color,
                    lineWidth: arrow.lineWidth
                )
            )
        case .text(let text):
            return .text(
                TextEdit(
                    id: text.id,
                    frame: text.frame.clamped(
                        to: bounds,
                        minimumSize: MupawConstants.minimumEditorObjectSize
                    ),
                    text: text.text,
                    color: text.color,
                    fontSize: text.fontSize
                )
            )
        case .mosaic(let mosaic):
            return .mosaic(
                MosaicEdit(
                    id: mosaic.id,
                    frame: mosaic.frame.clamped(
                        to: bounds,
                        minimumSize: MupawConstants.minimumEditorObjectSize
                    ),
                    blockSize: mosaic.blockSize
                )
            )
        }
    }
}

private struct EditObjectInspector: View {
    let object: ScreenshotEditObject
    let isBusy: Bool
    let onApply: (ScreenshotEditObject) -> Void

    @State private var textValue: String
    @State private var numericValue: Double
    @State private var colorValue: Color

    init(
        object: ScreenshotEditObject,
        isBusy: Bool,
        onApply: @escaping (ScreenshotEditObject) -> Void
    ) {
        self.object = object
        self.isBusy = isBusy
        self.onApply = onApply
        switch object {
        case .arrow(let arrow):
            _textValue = State(initialValue: "")
            _numericValue = State(initialValue: arrow.lineWidth)
            _colorValue = State(initialValue: Color(rgba: arrow.color))
        case .text(let text):
            _textValue = State(initialValue: text.text)
            _numericValue = State(initialValue: text.fontSize)
            _colorValue = State(initialValue: Color(rgba: text.color))
        case .mosaic(let mosaic):
            _textValue = State(initialValue: "")
            _numericValue = State(initialValue: mosaic.blockSize)
            _colorValue = State(initialValue: .clear)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.editKind(object.kind), systemImage: icon)
                .font(.headline)

            switch object {
            case .arrow:
                ColorPicker(L10n.string("editor.inspector.color"), selection: $colorValue)
                valueSlider(
                    title: L10n.string("editor.inspector.line_width"),
                    range: 1...MupawConstants.maximumEditorLineWidth
                )
            case .text:
                Text(L10n.string("editor.inspector.text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $textValue)
                    .font(.body)
                    .frame(minHeight: 72)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                ColorPicker(L10n.string("editor.inspector.color"), selection: $colorValue)
                valueSlider(
                    title: L10n.string("editor.inspector.font_size"),
                    range: MupawConstants.minimumEditorFontSize...MupawConstants.maximumEditorFontSize
                )
            case .mosaic:
                valueSlider(
                    title: L10n.string("editor.inspector.block_size"),
                    range: MupawConstants.minimumMosaicBlockSize...MupawConstants.maximumMosaicBlockSize
                )
            }

            Button(L10n.string("editor.inspector.apply")) {
                onApply(updatedObject)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isBusy || (object.kind == .text && textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    private func valueSlider(title: String, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", numericValue))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $numericValue, in: range)
        }
    }

    private var updatedObject: ScreenshotEditObject {
        switch object {
        case .arrow(let arrow):
            return .arrow(
                ArrowEdit(
                    id: arrow.id,
                    start: arrow.start,
                    end: arrow.end,
                    color: colorValue.rgba,
                    lineWidth: numericValue
                )
            )
        case .text(let text):
            return .text(
                TextEdit(
                    id: text.id,
                    frame: text.frame,
                    text: textValue,
                    color: colorValue.rgba,
                    fontSize: numericValue
                )
            )
        case .mosaic(let mosaic):
            return .mosaic(
                MosaicEdit(
                    id: mosaic.id,
                    frame: mosaic.frame,
                    blockSize: numericValue
                )
            )
        }
    }

    private var icon: String {
        switch object.kind {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

private struct CropEditorSheet: View {
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
        _draftRect = State(initialValue: project.content.cropRect ?? project.originalBounds)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.string("editor.crop.title"))
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

                    cropShade(imageFrame: mapping.imageFrame, selection: displayed)

                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
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
                Button(L10n.string("editor.crop.clear")) {
                    Task {
                        await model.setProjectCrop(nil)
                        dismiss()
                    }
                }
                .disabled(model.isBusy || project.content.cropRect == nil)
                Spacer()
                Button(L10n.string("common.cancel")) {
                    dismiss()
                }
                Button(L10n.string("editor.crop.apply")) {
                    Task {
                        await model.setProjectCrop(draftRect)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
        .padding(18)
        .frame(minWidth: 780, minHeight: 580)
    }

    private func cropShade(imageFrame: CGRect, selection: CGRect) -> some View {
        let clipped = selection.intersection(imageFrame)
        return ZStack {
            shadeRect(
                CGRect(
                    x: imageFrame.minX,
                    y: imageFrame.minY,
                    width: imageFrame.width,
                    height: max(0, clipped.minY - imageFrame.minY)
                )
            )
            shadeRect(
                CGRect(
                    x: imageFrame.minX,
                    y: clipped.maxY,
                    width: imageFrame.width,
                    height: max(0, imageFrame.maxY - clipped.maxY)
                )
            )
            shadeRect(
                CGRect(
                    x: imageFrame.minX,
                    y: clipped.minY,
                    width: max(0, clipped.minX - imageFrame.minX),
                    height: clipped.height
                )
            )
            shadeRect(
                CGRect(
                    x: clipped.maxX,
                    y: clipped.minY,
                    width: max(0, imageFrame.maxX - clipped.maxX),
                    height: clipped.height
                )
            )
        }
    }

    private func shadeRect(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.48))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

private struct EditorCanvasMapping {
    let visibleBounds: ImagePixelRect
    let imageFrame: CGRect
    let scale: CGFloat

    init(containerSize: CGSize, visibleBounds: ImagePixelRect) {
        self.visibleBounds = visibleBounds.standardized
        let safeWidth = max(1, self.visibleBounds.width)
        let safeHeight = max(1, self.visibleBounds.height)
        let padding: CGFloat = 20
        let available = CGSize(
            width: max(1, containerSize.width - padding * 2),
            height: max(1, containerSize.height - padding * 2)
        )
        scale = min(
            available.width / CGFloat(safeWidth),
            available.height / CGFloat(safeHeight)
        )
        let size = CGSize(
            width: CGFloat(safeWidth) * scale,
            height: CGFloat(safeHeight) * scale
        )
        imageFrame = CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func viewRect(for rect: ImagePixelRect) -> CGRect {
        let value = rect.standardized
        return CGRect(
            x: imageFrame.minX + CGFloat(value.minX - visibleBounds.minX) * scale,
            y: imageFrame.minY + CGFloat(value.minY - visibleBounds.minY) * scale,
            width: CGFloat(value.width) * scale,
            height: CGFloat(value.height) * scale
        )
    }

    func viewPoint(for point: ImagePixelPoint) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(point.x - visibleBounds.minX) * scale,
            y: imageFrame.minY + CGFloat(point.y - visibleBounds.minY) * scale
        )
    }

    func pixelDelta(for translation: CGSize) -> (width: Double, height: Double) {
        guard scale > 0 else { return (0, 0) }
        return (
            Double(translation.width / scale),
            Double(translation.height / scale)
        )
    }
}

extension ImagePreview {
    fileprivate var nsImage: NSImage? {
        guard let data = Data(base64Encoded: base64Data) else { return nil }
        return NSImage(data: data)
    }
}

extension Color {
    fileprivate init(rgba: RGBAColor) {
        self.init(
            .sRGB,
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: rgba.alpha
        )
    }

    fileprivate var rgba: RGBAColor {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return RGBAColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }
}
