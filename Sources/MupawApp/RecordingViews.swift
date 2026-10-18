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
        )
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
            }
            .font(.callout)
            .foregroundStyle(.secondary)
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
