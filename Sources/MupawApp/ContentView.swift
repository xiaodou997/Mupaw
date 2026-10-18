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
            "Mupaw could not complete the operation",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mupaw")
                    .font(.title2.bold())
                Text("Native capture for people and Agents")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                title: model.permissions.screenCapture == .authorized ? "Capture ready" : "Permission required",
                systemImage: model.permissions.screenCapture == .authorized
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            StatusPill(title: model.rpcStatus, systemImage: "point.3.connected.trianglepath.dotted")
        }
        .padding(18)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 9) {
                    permissionRow("Screen capture", model.permissions.screenCapture)
                    permissionRow("Microphone", model.permissions.microphone)
                    permissionRow("Camera", model.permissions.camera)
                    permissionRow("Accessibility", model.permissions.accessibility)
                    permissionRow("Input monitoring", model.permissions.inputMonitoring)

                    HStack {
                        Button("Refresh") {
                            model.refreshPermissions()
                        }
                        Button("Request screen access") {
                            model.requestScreenCapturePermission()
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Capture sources") {
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
                        Button("Refresh sources") {
                            Task { await model.refreshSources() }
                        }
                        Spacer()
                        Button("Capture") {
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
            Text("Latest artifact")
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
                    metadataRow("Source", artifact.source.title)
                    metadataRow("Size", "\(artifact.pixelWidth) × \(artifact.pixelHeight)")
                    metadataRow(
                        "Bytes", ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))
                    metadataRow("SHA-256", artifact.sha256)
                    metadataRow("File", artifact.fileURL.path)
                }
                .font(.caption)
                .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "No capture yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Select a source and capture it. Agent-created screenshots will appear here too.")
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
            Text(status.rawValue)
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
