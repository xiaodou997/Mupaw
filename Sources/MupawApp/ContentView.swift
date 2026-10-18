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
                sidebar
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                detail
                    .frame(minWidth: 440)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
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

            GroupBox(L10n.string("group.capture_sources")) {
                VStack(spacing: 8) {
                    List(model.sources, selection: $model.selectedSourceID) { source in
                        HStack {
                            Image(systemName: source.kind == .display ? "display" : "macwindow")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .lineLimit(1)
                                Text(sourceSubtitle(source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(source.id)
                    }
                    .frame(minHeight: 230)

                    HStack {
                        Button(L10n.string("action.refresh_sources")) {
                            Task { await model.refreshSources() }
                        }
                        Spacer()
                        Button(L10n.string("action.capture")) {
                            Task { await model.captureSelectedSource() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedSourceID == nil || model.isBusy)
                    }
                }
                .padding(6)
            }
        }
        .padding(16)
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
        return "\(owner)\(source.pixelWidth) × \(source.pixelHeight)"
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
