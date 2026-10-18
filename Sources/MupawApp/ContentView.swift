import AppKit
import MupawCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView {
                    sidebar
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                detail
                    .frame(minWidth: 460)
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .task {
            await model.start()
        }
        .alert(
            L10n.string("alert.operation_failed.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok"), role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? L10n.string("error.unknown"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mupaw")
                    .font(.title2.bold())
                Text(L10n.string("app.tagline"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            StatusPill(
                title: model.permissions.screenCapture == .authorized
                    ? L10n.string("status.capture_ready")
                    : L10n.string("status.permission_required"),
                systemImage: model.permissions.screenCapture == .authorized
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            StatusPill(title: model.rpcStatus, systemImage: "point.3.connected.trianglepath.dotted")
        }
        .padding(18)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            captureGroup
            shortcutsGroup
            permissionsGroup
        }
        .padding(16)
    }

    private var captureGroup: some View {
        GroupBox(L10n.string("group.screenshot")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L10n.string("capture.mode.label"), selection: $model.selectedCaptureMode) {
                    ForEach(ScreenshotCaptureMode.allCases, id: \.self) { mode in
                        Text(L10n.captureMode(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(L10n.string("toggle.include_cursor"), isOn: $model.includeCursor)

                if model.selectedCaptureMode == .region {
                    Text(L10n.string("capture.region.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await model.captureSelectedMode() }
                    } label: {
                        Label(
                            model.isSelectingRegion
                                ? L10n.string("capture.region.selecting")
                                : L10n.string("action.select_region"),
                            systemImage: "viewfinder"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(captureDisabled)
                } else {
                    List(model.captureSources, selection: $model.selectedSourceID) { source in
                        sourceRow(source)
                            .tag(source.id)
                    }
                    .frame(minHeight: 220, idealHeight: 280)

                    HStack {
                        Button(L10n.string("action.refresh_sources")) {
                            Task { await model.refreshSources() }
                        }
                        Spacer()
                        Button(captureButtonTitle) {
                            Task { await model.captureSelectedMode() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(captureDisabled || model.selectedSourceID == nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var shortcutsGroup: some View {
        GroupBox(L10n.string("group.shortcuts")) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(model.hotKeyRegistrations) { registration in
                    HStack(spacing: 8) {
                        Image(systemName: shortcutIcon(registration.shortcut))
                        Text(shortcutTitle(registration.shortcut))
                        Spacer()
                        Text(registration.shortcut.displayText)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        shortcutState(registration.state)
                    }
                }
                if model.hotKeyRegistrations.contains(where: { $0.state != .registered }) {
                    Button(L10n.string("action.retry_shortcuts")) {
                        model.retryGlobalHotKeys()
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var permissionsGroup: some View {
        GroupBox(L10n.string("group.permissions")) {
            VStack(alignment: .leading, spacing: 9) {
                permissionRow(L10n.string("permission.screen_capture"), model.permissions.screenCapture)
                permissionRow(L10n.string("permission.microphone"), model.permissions.microphone)
                permissionRow(L10n.string("permission.camera"), model.permissions.camera)
                permissionRow(L10n.string("permission.accessibility"), model.permissions.accessibility)
                permissionRow(L10n.string("permission.input_monitoring"), model.permissions.inputMonitoring)

                HStack {
                    Button(L10n.string("action.refresh")) {
                        model.refreshPermissions()
                    }
                    Button(L10n.string("action.request_screen_access")) {
                        model.requestScreenCapturePermission()
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("section.latest_artifact"))
                .font(.headline)

            if let artifact = model.lastArtifact,
                let image = NSImage(contentsOf: artifact.fileURL)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    metadataRow(L10n.string("metadata.mode"), L10n.sourceKind(artifact.source.kind))
                    metadataRow(L10n.string("metadata.source"), artifact.source.title)
                    metadataRow(
                        L10n.string("metadata.size"),
                        "\(artifact.pixelWidth) × \(artifact.pixelHeight)"
                    )
                    metadataRow(
                        L10n.string("metadata.bytes"),
                        ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file)
                    )
                    metadataRow(L10n.string("metadata.sha256"), artifact.sha256)
                    metadataRow(L10n.string("metadata.file"), artifact.fileURL.path)
                }
                .font(.caption)
                .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    L10n.string("empty.no_capture.title"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(L10n.string("empty.no_capture.description"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
    }

    private var captureDisabled: Bool {
        model.isBusy || model.permissions.screenCapture != .authorized
    }

    private var captureButtonTitle: String {
        switch model.selectedCaptureMode {
        case .fullScreen:
            return L10n.string("action.capture_full_screen")
        case .window:
            return L10n.string("action.capture_window")
        case .region:
            return L10n.string("action.select_region")
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: CaptureSourceDescriptor) -> some View {
        HStack {
            Image(systemName: source.kind == .display ? "display" : "macwindow")
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .lineLimit(1)
                Text(sourceSubtitle(source))
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

    private func permissionRow(_ title: String, _ status: PermissionStatus) -> some View {
        HStack {
            Image(systemName: status == .authorized ? "checkmark.circle.fill" : "circle.dashed")
            Text(title)
            Spacer()
            Text(L10n.permissionStatus(status))
                .foregroundStyle(.secondary)
        }
    }

    private func sourceSubtitle(_ source: CaptureSourceDescriptor) -> String {
        let owner = source.applicationName.map { "\($0) · " } ?? ""
        let scale = source.pointPixelScale.map { String(format: " · %.1f×", $0) } ?? ""
        return "\(owner)\(source.pixelWidth) × \(source.pixelHeight)\(scale)"
    }

    private func shortcutTitle(_ shortcut: GlobalCaptureShortcut) -> String {
        switch shortcut {
        case .fullScreen:
            return L10n.string("shortcut.full_screen")
        case .window:
            return L10n.string("shortcut.window")
        case .region:
            return L10n.string("shortcut.region")
        }
    }

    private func shortcutIcon(_ shortcut: GlobalCaptureShortcut) -> String {
        switch shortcut {
        case .fullScreen:
            return "display"
        case .window:
            return "macwindow"
        case .region:
            return "viewfinder"
        }
    }

    @ViewBuilder
    private func shortcutState(_ state: GlobalHotKeyRegistration.State) -> some View {
        switch state {
        case .registered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(L10n.string("shortcut.status.registered"))
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(L10n.string("shortcut.status.conflict"))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(L10n.string("shortcut.status.failed"))
        }
    }

    @ViewBuilder
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

private struct StatusPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
}
