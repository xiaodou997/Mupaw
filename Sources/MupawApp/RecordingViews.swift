import AppKit
import MupawCore
import SwiftUI

struct RecordingSidebarGroup: View {
    @Bindable var model: AppModel

    var body: some View {
        GroupBox(L10n.string("group.recording")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L10n.string("recording.mode.label"), selection: $model.selectedCaptureMode) {
                    ForEach(ScreenshotCaptureMode.allCases, id: \.self) { mode in
                        Text(L10n.captureMode(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.hasActiveRecording)

                Toggle(L10n.string("toggle.include_cursor"), isOn: $model.includeCursor)
                    .disabled(model.hasActiveRecording)

                Picker(
                    L10n.string("recording.audio_source"),
                    selection: $model.recordingAudioSource
                ) {
                    ForEach(RecordingAudioSource.allCases, id: \.self) { source in
                        Text(L10n.recordingAudioSource(source)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.hasActiveRecording)

                if model.recordingAudioSource.usesMicrophone {
                    microphoneControls
                }

                if model.recordingAudioSource.usesSystemAudio {
                    audioLaneControls(
                        title: L10n.string("recording.audio.system_audio"),
                        systemImage: "speaker.wave.2.fill",
                        gain: systemAudioGainBinding,
                        muted: systemAudioMutedBinding,
                        input: model.currentRecordingStatus?.audio.systemAudioInput
                    )
                }

                if model.recordingAudioSource.usesMicrophone {
                    audioLaneControls(
                        title: L10n.string("recording.audio.microphone"),
                        systemImage: "mic.fill",
                        gain: microphoneGainBinding,
                        muted: microphoneMutedBinding,
                        input: model.currentRecordingStatus?.audio.microphoneInput
                    )
                }

                Toggle(
                    L10n.string("recording.camera.overlay"),
                    isOn: $model.recordingCameraEnabled
                )
                .disabled(model.hasActiveRecording)

                if model.recordingCameraEnabled {
                    cameraControls
                }

                HStack {
                    Picker(L10n.string("recording.frame_rate"), selection: $model.recordingFrameRate) {
                        ForEach(MupawConstants.supportedRecordingFrameRates, id: \.self) { value in
                            Text(L10n.format("recording.frame_rate.value.format", value)).tag(value)
                        }
                    }
                    Picker(L10n.string("recording.quality"), selection: $model.recordingQuality) {
                        ForEach(RecordingVideoQuality.allCases, id: \.self) { quality in
                            Text(L10n.recordingQuality(quality)).tag(quality)
                        }
                    }
                }
                .disabled(model.hasActiveRecording)

                if let status = model.currentRecordingStatus, status.phase.isActive {
                    activeControls(status)
                } else if model.selectedCaptureMode == .region {
                    Text(L10n.string("recording.region.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    startButton
                } else {
                    List(model.captureSources, selection: $model.selectedSourceID) { source in
                        sourceRow(source)
                            .tag(source.id)
                    }
                    .frame(minHeight: 180, idealHeight: 220)
                    .disabled(model.hasActiveRecording)

                    HStack {
                        Button(L10n.string("action.refresh_sources")) {
                            Task { await model.refreshSources() }
                        }
                        Spacer()
                        startButton
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var startButton: some View {
        Button {
            Task { await model.startSelectedRecording() }
        } label: {
            Label(
                model.isSelectingRegion
                    ? L10n.string("recording.region.selecting")
                    : L10n.string("recording.action.start"),
                systemImage: "record.circle"
            )
            .frame(maxWidth: model.selectedCaptureMode == .region ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(
            model.isBusy
                || model.hasActiveRecording
                || model.permissions.screenCapture != .authorized
                || (model.selectedCaptureMode != .region && model.selectedSourceID == nil)
                || (model.recordingAudioSource.usesMicrophone
                    && (model.permissions.microphone != .authorized
                        || model.selectedMicrophoneDeviceID == nil))
                || (model.recordingCameraEnabled
                    && (model.permissions.camera != .authorized
                        || model.selectedCameraDeviceID == nil))
        )
    }

    private var systemAudioGainBinding: Binding<Double> {
        Binding(
            get: { model.recordingSystemAudioGain },
            set: {
                model.recordingSystemAudioGain = $0
                model.scheduleRecordingAudioControlUpdate()
            }
        )
    }

    private var microphoneGainBinding: Binding<Double> {
        Binding(
            get: { model.recordingMicrophoneGain },
            set: {
                model.recordingMicrophoneGain = $0
                model.scheduleRecordingAudioControlUpdate()
            }
        )
    }

    private var systemAudioMutedBinding: Binding<Bool> {
        Binding(
            get: { model.recordingSystemAudioMuted },
            set: {
                model.recordingSystemAudioMuted = $0
                model.scheduleRecordingAudioControlUpdate()
            }
        )
    }

    private var microphoneMutedBinding: Binding<Bool> {
        Binding(
            get: { model.recordingMicrophoneMuted },
            set: {
                model.recordingMicrophoneMuted = $0
                model.scheduleRecordingAudioControlUpdate()
            }
        )
    }

    private var cameraVisibleBinding: Binding<Bool> {
        Binding(
            get: { model.recordingCameraVisible },
            set: {
                model.recordingCameraVisible = $0
                model.scheduleRecordingCameraOverlayUpdate()
            }
        )
    }

    private var cameraPositionBinding: Binding<RecordingCameraOverlayPosition> {
        Binding(
            get: { model.recordingCameraPosition },
            set: {
                model.recordingCameraPosition = $0
                model.scheduleRecordingCameraOverlayUpdate()
            }
        )
    }

    private var cameraSizeBinding: Binding<RecordingCameraOverlaySize> {
        Binding(
            get: { model.recordingCameraSize },
            set: {
                model.recordingCameraSize = $0
                model.scheduleRecordingCameraOverlayUpdate()
            }
        )
    }

    private var cameraShapeBinding: Binding<RecordingCameraOverlayShape> {
        Binding(
            get: { model.recordingCameraShape },
            set: {
                model.recordingCameraShape = $0
                model.scheduleRecordingCameraOverlayUpdate()
            }
        )
    }

    private var cameraCornerRadiusBinding: Binding<Double> {
        Binding(
            get: { model.recordingCameraCornerRadius },
            set: {
                model.recordingCameraCornerRadius = $0
                model.scheduleRecordingCameraOverlayUpdate()
            }
        )
    }

    private var cameraMarginBinding: Binding<Double> {
        Binding(
            get: { model.recordingCameraMargin },
            set: {
                model.recordingCameraMargin = $0
                model.scheduleRecordingCameraOverlayUpdate()
            }
        )
    }

    private func audioLaneControls(
        title: String,
        systemImage: String,
        gain: Binding<Double>,
        muted: Binding<Bool>,
        input: RecordingAudioInputInfo?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle(L10n.string("recording.audio.mute"), isOn: muted)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            HStack(spacing: 8) {
                Slider(
                    value: gain,
                    in: MupawConstants.minimumRecordingAudioGain...MupawConstants.maximumRecordingAudioGain,
                    step: 0.05
                )
                Text(String(format: "%.2f×", gain.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
            RecordingAudioLevelMeter(level: input?.currentLevel)
        }
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var microphoneControls: some View {
        if model.permissions.microphone == .authorized {
            Picker(
                L10n.string("recording.microphone.device"),
                selection: $model.selectedMicrophoneDeviceID
            ) {
                ForEach(model.microphoneDevices) { device in
                    Text(
                        device.isDefault
                            ? L10n.format("recording.microphone.default.format", device.name)
                            : device.name
                    )
                    .tag(Optional(device.id))
                }
            }
            .disabled(model.hasActiveRecording || model.microphoneDevices.isEmpty)

            HStack {
                Text(
                    model.microphoneDevices.isEmpty
                        ? L10n.string("recording.microphone.none")
                        : L10n.string("recording.microphone.description")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("recording.microphone.refresh")) {
                    model.refreshMicrophoneDevices()
                }
                .disabled(model.hasActiveRecording)
            }
        } else {
            Text(
                L10n.format(
                    "recording.microphone.permission_status.format",
                    L10n.permissionStatus(model.permissions.microphone)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("recording.microphone.request_permission")) {
                    Task { await model.requestMicrophonePermission() }
                }
                Button(L10n.string("recording.microphone.open_settings")) {
                    model.openMicrophonePrivacySettings()
                }
            }
            .disabled(model.hasActiveRecording)
        }
    }

    @ViewBuilder
    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.permissions.camera == .authorized {
                Picker(
                    L10n.string("recording.camera.device"),
                    selection: $model.selectedCameraDeviceID
                ) {
                    ForEach(model.cameraDevices) { device in
                        Text(
                            device.isDefault
                                ? L10n.format("recording.camera.default.format", device.name)
                                : device.name
                        )
                        .tag(Optional(device.id))
                    }
                }
                .disabled(model.hasActiveRecording || model.cameraDevices.isEmpty)

                HStack {
                    Text(
                        model.cameraDevices.isEmpty
                            ? L10n.string("recording.camera.none")
                            : L10n.string("recording.camera.description")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("recording.camera.refresh")) {
                        model.refreshCameraDevices()
                    }
                    .disabled(model.hasActiveRecording)
                }

                Toggle(
                    L10n.string("recording.camera.visible"),
                    isOn: cameraVisibleBinding
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                    GridRow {
                        Text(L10n.string("recording.camera.position"))
                        Picker(
                            L10n.string("recording.camera.position"),
                            selection: cameraPositionBinding
                        ) {
                            ForEach(RecordingCameraOverlayPosition.allCases, id: \.self) {
                                position in
                                Text(L10n.recordingCameraPosition(position)).tag(position)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text(L10n.string("recording.camera.size"))
                        Picker(
                            L10n.string("recording.camera.size"),
                            selection: cameraSizeBinding
                        ) {
                            ForEach(RecordingCameraOverlaySize.allCases, id: \.self) { size in
                                Text(L10n.recordingCameraSize(size)).tag(size)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text(L10n.string("recording.camera.shape"))
                        Picker(
                            L10n.string("recording.camera.shape"),
                            selection: cameraShapeBinding
                        ) {
                            ForEach(RecordingCameraOverlayShape.allCases, id: \.self) { shape in
                                Text(L10n.recordingCameraShape(shape)).tag(shape)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text(L10n.string("recording.camera.corner_radius"))
                        HStack(spacing: 8) {
                            Slider(
                                value: cameraCornerRadiusBinding,
                                in: MupawConstants
                                    .minimumRecordingCameraCornerRadius...MupawConstants
                                    .maximumRecordingCameraCornerRadius,
                                step: 0.01
                            )
                            Text(
                                L10n.format(
                                    "recording.camera.percent.format",
                                    model.recordingCameraCornerRadius * 100
                                )
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                        }
                        .disabled(model.recordingCameraShape == .circle)
                    }
                    GridRow {
                        Text(L10n.string("recording.camera.margin"))
                        HStack(spacing: 8) {
                            Slider(
                                value: cameraMarginBinding,
                                in: MupawConstants
                                    .minimumRecordingCameraMargin...MupawConstants.maximumRecordingCameraMargin,
                                step: 0.005
                            )
                            Text(
                                L10n.format(
                                    "recording.camera.percent.format",
                                    model.recordingCameraMargin * 100
                                )
                            )
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                .font(.caption)

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("recording.camera.preview"))
                        .font(.caption.weight(.semibold))
                    RecordingCameraLayoutPreview(
                        visible: model.recordingCameraVisible,
                        position: model.recordingCameraPosition,
                        size: model.recordingCameraSize,
                        shape: model.recordingCameraShape,
                        cornerRadius: model.recordingCameraCornerRadius,
                        margin: model.recordingCameraMargin
                    )
                }
            } else {
                Text(
                    L10n.format(
                        "recording.camera.permission_status.format",
                        L10n.permissionStatus(model.permissions.camera)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.string("recording.camera.request_permission")) {
                        Task { await model.requestCameraPermission() }
                    }
                    Button(L10n.string("recording.camera.open_settings")) {
                        model.openCameraPrivacySettings()
                    }
                }
                .disabled(model.hasActiveRecording)
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func activeControls(_ status: RecordingSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text(L10n.recordingPhase(status.phase))
                    .font(.headline)
                Spacer()
                Text(RecordingTimeFormatter.string(status.elapsedDurationSeconds))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }
            Text(status.source.title)
                .font(.callout)
                .lineLimit(1)
            Text(
                "\(status.pixelWidth) × \(status.pixelHeight) · \(L10n.format("recording.frame_rate.value.format", status.frameRate))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Label(
                    L10n.recordingAudioState(status.audio.state),
                    systemImage: audioIcon(status.audio.source)
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if status.camera.requested {
                    Label(
                        L10n.recordingCameraState(status.camera.state),
                        systemImage: "video.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(status.camera.isStale ? .orange : .secondary)
                }
                if status.camera.requested {
                    Text(
                        status.camera.visible == true
                            ? L10n.string("recording.camera.visible.on")
                            : L10n.string("recording.camera.visible.off")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    Task { await model.cancelCurrentRecording() }
                } label: {
                    Label(L10n.string("recording.action.cancel"), systemImage: "xmark")
                }
                Spacer()
                Button {
                    Task { await model.stopCurrentRecording() }
                } label: {
                    Label(L10n.string("recording.action.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .disabled(model.isBusy)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func audioIcon(_ source: RecordingAudioSource) -> String {
        switch source {
        case .none:
            return "speaker.slash.fill"
        case .systemAudio:
            return "speaker.wave.2.fill"
        case .microphone:
            return "mic.fill"
        case .systemAudioAndMicrophone:
            return "waveform.and.mic"
        }
    }

    private func sourceRow(_ source: CaptureSourceDescriptor) -> some View {
        HStack {
            Image(systemName: source.kind == .display ? "display" : "macwindow")
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .lineLimit(1)
                let owner = source.applicationName.map { "\($0) · " } ?? ""
                Text("\(owner)\(source.pixelWidth) × \(source.pixelHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if source.isActive == true || source.isPrimaryDisplay == true {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct RecordingCameraLayoutPreview: View {
    let visible: Bool
    let position: RecordingCameraOverlayPosition
    let size: RecordingCameraOverlaySize
    let shape: RecordingCameraOverlayShape
    let cornerRadius: Double
    let margin: Double

    var body: some View {
        GeometryReader { proxy in
            let shortest = min(proxy.size.width, proxy.size.height)
            let extent = shortest * sizeFactor
            let inset = shortest * CGFloat(margin)
            let center = overlayCenter(
                canvas: proxy.size,
                extent: extent,
                inset: inset
            )

            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.secondary.opacity(0.12))
                Image(systemName: "display")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary.opacity(0.55))
                if visible {
                    Group {
                        if shape == .circle {
                            Circle()
                                .fill(.tint.opacity(0.85))
                        } else {
                            RoundedRectangle(
                                cornerRadius: max(1, extent * CGFloat(cornerRadius))
                            )
                            .fill(.tint.opacity(0.85))
                        }
                    }
                    .frame(width: extent, height: extent)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .position(center)
                    .animation(.easeInOut(duration: 0.14), value: position)
                    .animation(.easeInOut(duration: 0.14), value: size)
                    .animation(.easeInOut(duration: 0.14), value: shape)
                    .animation(.easeInOut(duration: 0.14), value: cornerRadius)
                    .animation(.easeInOut(duration: 0.14), value: margin)
                }
            }
        }
        .frame(height: 92)
        .accessibilityLabel(L10n.string("recording.camera.preview"))
    }

    private var sizeFactor: CGFloat {
        switch size {
        case .small:
            return 0.25
        case .medium:
            return 0.34
        case .large:
            return 0.44
        }
    }

    private func overlayCenter(
        canvas: CGSize,
        extent: CGFloat,
        inset: CGFloat
    ) -> CGPoint {
        let leading = inset + extent / 2
        let trailing = canvas.width - inset - extent / 2
        let top = inset + extent / 2
        let bottom = canvas.height - inset - extent / 2
        switch position {
        case .topLeft:
            return CGPoint(x: leading, y: top)
        case .topRight:
            return CGPoint(x: trailing, y: top)
        case .bottomLeft:
            return CGPoint(x: leading, y: bottom)
        case .bottomRight:
            return CGPoint(x: trailing, y: bottom)
        }
    }
}

private struct RecordingAudioLevelMeter: View {
    let level: RecordingAudioLevel?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.16))
                    Capsule()
                        .fill(level?.isStale == true ? Color.secondary : Color.green)
                        .frame(width: proxy.size.width * CGFloat(displayPeak))
                        .animation(.linear(duration: 0.14), value: displayPeak)
                    Capsule()
                        .fill(.primary.opacity(0.45))
                        .frame(width: proxy.size.width * CGFloat(displayRMS))
                        .frame(height: 3)
                        .animation(.linear(duration: 0.14), value: displayRMS)
                }
            }
            .frame(height: 7)

            HStack {
                Text(
                    L10n.format(
                        "recording.audio.level.rms.format",
                        level?.rms ?? 0
                    )
                )
                Spacer()
                Text(
                    level?.isStale == true
                        ? L10n.string("recording.audio.level.stale")
                        : L10n.format(
                            "recording.audio.level.peak.format",
                            level?.peak ?? 0
                        )
                )
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var displayRMS: Double {
        max(0, min(1, level?.isStale == false ? level?.rms ?? 0 : 0))
    }

    private var displayPeak: Double {
        max(0, min(1, level?.isStale == false ? level?.peak ?? 0 : 0))
    }
}

struct RecordingDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("recording.detail.title"))
                .font(.headline)

            if let status = model.currentRecordingStatus, status.phase.isActive {
                activeView(status)
            } else if let artifact = model.lastRecordingArtifact,
                let image = artifact.preview.nsImageForRecording
            {
                completedView(artifact, image: image)
            } else {
                emptyView
            }
        }
        .padding(18)
    }

    private func activeView(_ status: RecordingSessionStatus) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.red.opacity(0.12))
                    .frame(width: 132, height: 132)
                Circle()
                    .fill(.red)
                    .frame(width: 58, height: 58)
            }
            Text(L10n.recordingPhase(status.phase))
                .font(.title2.bold())
            Text(RecordingTimeFormatter.string(status.elapsedDurationSeconds))
                .font(.system(size: 38, weight: .semibold, design: .monospaced))
            Text(status.source.title)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Label("\(status.pixelWidth) × \(status.pixelHeight)", systemImage: "rectangle")
                Label(
                    L10n.format("recording.frame_rate.value.format", status.frameRate),
                    systemImage: "film.stack"
                )
                Label(L10n.recordingQuality(status.quality), systemImage: "dial.medium")
                Label(
                    L10n.recordingAudioState(status.audio.state),
                    systemImage: audioIcon(status.audio.source)
                )
                if status.camera.requested {
                    Label(
                        L10n.recordingCameraState(status.camera.state),
                        systemImage: "video.fill"
                    )
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if status.audio.source.isEnabled {
                HStack(spacing: 16) {
                    if status.audio.source.usesSystemAudio {
                        activeLaneMeter(
                            L10n.string("recording.audio.system_audio"),
                            level: status.audio.systemAudioInput?.currentLevel
                        )
                    }
                    if status.audio.source.usesMicrophone {
                        activeLaneMeter(
                            L10n.string("recording.audio.microphone"),
                            level: status.audio.microphoneInput?.currentLevel
                        )
                    }
                    if status.audio.source.isMixed {
                        activeLaneMeter(
                            L10n.string("recording.audio.mixed_output"),
                            level: status.audio.mixedLevel
                        )
                    }
                }
                .frame(maxWidth: 620)
            }
            if status.camera.requested {
                HStack(spacing: 12) {
                    Label(
                        status.camera.deviceName
                            ?? L10n.string("recording.camera.device_unknown"),
                        systemImage: "video.fill"
                    )
                    Label(
                        L10n.format(
                            "recording.camera.frames.format",
                            status.camera.frameCount
                        ),
                        systemImage: "film.stack"
                    )
                    if status.camera.isStale {
                        Label(
                            L10n.string("recording.camera.frame_stale"),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    Task { await model.cancelCurrentRecording() }
                } label: {
                    Label(L10n.string("recording.action.cancel"), systemImage: "xmark")
                }
                Button {
                    Task { await model.stopCurrentRecording() }
                } label: {
                    Label(L10n.string("recording.action.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .disabled(model.isBusy)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completedView(_ artifact: RecordingArtifact, image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                metadataRow(L10n.string("metadata.mode"), L10n.sourceKind(artifact.source.kind))
                metadataRow(L10n.string("metadata.source"), artifact.source.title)
                metadataRow(
                    L10n.string("metadata.duration"),
                    RecordingTimeFormatter.preciseString(artifact.durationSeconds)
                )
                metadataRow(
                    L10n.string("metadata.size"),
                    "\(artifact.pixelWidth) × \(artifact.pixelHeight)"
                )
                metadataRow(
                    L10n.string("recording.metadata.frame_rate"),
                    String(format: "%.2f fps", artifact.averageFrameRate)
                )
                metadataRow(L10n.string("recording.metadata.codec"), "H.264 · MP4")
                metadataRow(
                    L10n.string("recording.metadata.audio_source"),
                    L10n.recordingAudioSource(artifact.audio.source)
                )
                metadataRow(
                    L10n.string("recording.metadata.audio_state"),
                    L10n.recordingAudioState(artifact.audio.state)
                )
                if artifact.audio.requested {
                    if let deviceName = artifact.audio.deviceName {
                        metadataRow(
                            L10n.string("recording.metadata.audio_device"),
                            deviceName
                        )
                    }
                    metadataRow(
                        L10n.string("recording.metadata.audio_codec"),
                        L10n.string("recording.audio.codec.aac")
                    )
                    if let sampleRate = artifact.audio.sampleRate {
                        metadataRow(
                            L10n.string("recording.metadata.audio_sample_rate"),
                            L10n.format("recording.audio.sample_rate.format", sampleRate)
                        )
                    }
                    if let channelCount = artifact.audio.channelCount {
                        metadataRow(
                            L10n.string("recording.metadata.audio_channels"),
                            L10n.format("recording.audio.channels.format", channelCount)
                        )
                    }
                    if let audioDuration = artifact.audio.durationSeconds {
                        metadataRow(
                            L10n.string("recording.metadata.audio_duration"),
                            RecordingTimeFormatter.preciseString(audioDuration)
                        )
                    }
                    if let difference = artifact.audio.audioVideoDurationDifferenceSeconds {
                        metadataRow(
                            L10n.string("recording.metadata.audio_sync_difference"),
                            RecordingTimeFormatter.preciseString(difference)
                        )
                    }
                    metadataRow(
                        L10n.string("recording.metadata.system_audio_gain"),
                        String(format: "%.2f×", artifact.audio.controls.systemAudioGain)
                    )
                    metadataRow(
                        L10n.string("recording.metadata.microphone_gain"),
                        String(format: "%.2f×", artifact.audio.controls.microphoneGain)
                    )
                    metadataRow(
                        L10n.string("recording.metadata.mute_state"),
                        L10n.format(
                            "recording.metadata.mute_state.format",
                            artifact.audio.controls.systemAudioMuted
                                ? L10n.string("recording.audio.muted")
                                : L10n.string("recording.audio.unmuted"),
                            artifact.audio.controls.microphoneMuted
                                ? L10n.string("recording.audio.muted")
                                : L10n.string("recording.audio.unmuted")
                        )
                    )
                    metadataRow(
                        L10n.string("recording.metadata.control_events"),
                        String(artifact.audio.controlEventCount)
                    )
                }
                metadataRow(
                    L10n.string("recording.metadata.camera_state"),
                    L10n.recordingCameraState(artifact.camera.state)
                )
                if artifact.camera.requested {
                    if let deviceName = artifact.camera.deviceName {
                        metadataRow(
                            L10n.string("recording.metadata.camera_device"),
                            deviceName
                        )
                    }
                    if let position = artifact.camera.position {
                        metadataRow(
                            L10n.string("recording.metadata.camera_position"),
                            L10n.recordingCameraPosition(position)
                        )
                    }
                    if let size = artifact.camera.size {
                        metadataRow(
                            L10n.string("recording.metadata.camera_size"),
                            L10n.recordingCameraSize(size)
                        )
                    }
                    if let shape = artifact.camera.shape {
                        metadataRow(
                            L10n.string("recording.metadata.camera_shape"),
                            L10n.recordingCameraShape(shape)
                        )
                    }
                    metadataRow(
                        L10n.string("recording.metadata.camera_visible"),
                        artifact.camera.visible == true
                            ? L10n.string("recording.camera.visible.on")
                            : L10n.string("recording.camera.visible.off")
                    )
                    if let cornerRadius = artifact.camera.cornerRadius {
                        metadataRow(
                            L10n.string("recording.metadata.camera_corner_radius"),
                            L10n.format("recording.camera.percent.format", cornerRadius * 100)
                        )
                    }
                    if let margin = artifact.camera.margin {
                        metadataRow(
                            L10n.string("recording.metadata.camera_margin"),
                            L10n.format("recording.camera.percent.format", margin * 100)
                        )
                    }
                    metadataRow(
                        L10n.string("recording.metadata.camera_control_events"),
                        String(artifact.camera.controlEventCount)
                    )
                    metadataRow(
                        L10n.string("recording.metadata.camera_frames"),
                        String(artifact.camera.frameCount)
                    )
                    if let width = artifact.camera.sourcePixelWidth,
                        let height = artifact.camera.sourcePixelHeight
                    {
                        metadataRow(
                            L10n.string("recording.metadata.camera_source_size"),
                            "\(width) × \(height)"
                        )
                    }
                    if let rect = artifact.camera.overlayRectPixels {
                        metadataRow(
                            L10n.string("recording.metadata.camera_overlay_rect"),
                            String(
                                format: "x %.0f · y %.0f · %.0f × %.0f",
                                rect.x,
                                rect.y,
                                rect.width,
                                rect.height
                            )
                        )
                    }
                }
                metadataRow(
                    L10n.string("metadata.bytes"),
                    ByteCountFormatter.string(
                        fromByteCount: Int64(artifact.byteCount),
                        countStyle: .file
                    )
                )
                metadataRow(L10n.string("metadata.sha256"), artifact.sha256)
                metadataRow(L10n.string("metadata.file"), artifact.fileURL.path)
            }
            .font(.caption)
            .textSelection(.enabled)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L10n.string("recording.empty.title"),
            systemImage: "record.circle",
            description: Text(L10n.string("recording.empty.description"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func audioIcon(_ source: RecordingAudioSource) -> String {
        switch source {
        case .none:
            return "speaker.slash.fill"
        case .systemAudio:
            return "speaker.wave.2.fill"
        case .microphone:
            return "mic.fill"
        case .systemAudioAndMicrophone:
            return "waveform.and.mic"
        }
    }

    private func activeLaneMeter(_ title: String, level: RecordingAudioLevel?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            RecordingAudioLevelMeter(level: level)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

enum RecordingTimeFormatter {
    static func string(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%02d:%02d", minutes, remaining)
    }

    static func preciseString(_ seconds: Double) -> String {
        String(format: "%.2f s", max(0, seconds))
    }
}

extension ImagePreview {
    fileprivate var nsImageForRecording: NSImage? {
        guard let data = Data(base64Encoded: base64Data) else { return nil }
        return NSImage(data: data)
    }
}
