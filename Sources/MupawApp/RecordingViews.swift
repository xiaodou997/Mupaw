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
