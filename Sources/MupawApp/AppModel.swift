import Foundation
import MupawCapture
import MupawCore
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var permissions = PermissionSnapshot(
        screenCapture: .denied,
        microphone: .notDetermined,
        camera: .notDetermined,
        accessibility: .denied,
        inputMonitoring: .denied
    )
    private(set) var sources: [CaptureSourceDescriptor] = []
    var selectedSourceID: String?
    private(set) var lastArtifact: ScreenshotArtifact?
    private(set) var rpcStatus = L10n.string("rpc.not_started")
    private(set) var isBusy = false
    var errorMessage: String?

    private let paths: MupawPaths
    private let captureService: CaptureService
    private let permissionService = PermissionService()
    private var rpcServer: AgentRPCServer?
    private var hasStarted = false

    init() {
        do {
            let paths = try MupawPaths.live()
            self.paths = paths
            self.captureService = CaptureService(paths: paths)
        } catch {
            let fallback = MupawPaths(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Mupaw", isDirectory: true)
            )
            self.paths = fallback
            self.captureService = CaptureService(paths: fallback)
            self.errorMessage = L10n.format(
                "error.app_support_fallback.format",
                error.localizedDescription
            )
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        refreshPermissions()

        do {
            let server = AgentRPCServer(
                descriptorStore: AgentConnectionDescriptorStore(paths: paths)
            ) { [weak self] request in
                guard let self else {
                    return .failure(id: request.id, code: .appNotRunning, message: "Mupaw is shutting down.")
                }
                return await self.handleRPC(request)
            }
            let descriptor = try server.start()
            rpcServer = server
            rpcStatus = L10n.format("rpc.ready.format", Int(descriptor.port))
        } catch {
            rpcStatus = L10n.string("rpc.failed")
            errorMessage = localizedMessage(for: error)
        }

        if permissions.screenCapture == .authorized {
            await refreshSources()
        }
    }

    func shutdown() {
        rpcServer?.stop()
        rpcServer = nil
        rpcStatus = L10n.string("rpc.stopped")
    }

    func refreshPermissions(forceRefresh: Bool = true) {
        permissions = permissionService.snapshot(forceRefresh: forceRefresh)
    }

    func requestScreenCapturePermission() {
        _ = permissionService.requestScreenCaptureAccess()
        refreshPermissions()
    }

    func refreshSources() async {
        await performBusyWork {
            let result = try await captureService.listSources(forceRefresh: true)
            sources = result.sources
            if selectedSourceID == nil || !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = sources.first?.id
            }
        }
    }

    func captureSelectedSource() async {
        guard let selectedSourceID else {
            errorMessage = L10n.string("error.select_source")
            return
        }
        await performBusyWork {
            lastArtifact = try await captureService.capture(
                ScreenshotRequest(sourceID: selectedSourceID)
            )
        }
    }

    private func performBusyWork(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        do {
            try await operation()
        } catch {
            errorMessage = localizedMessage(for: error)
            refreshPermissions()
        }
    }

    private func localizedMessage(for error: Error) -> String {
        if let captureError = error as? CaptureServiceError {
            switch captureError {
            case .sourceNotFound(let identifier):
                return L10n.format("capture.error.source_not_found.format", identifier)
            case .invalidSourceSize(let identifier):
                return L10n.format("capture.error.invalid_source_size.format", identifier)
            }
        }
        return error.localizedDescription
    }

    private func handleRPC(_ request: AgentRPCRequest) async -> AgentRPCResponse {
        do {
            switch request.method {
            case .ping:
                return try .success(id: request.id, value: EmptyPayload())

            case .appStatus:
                refreshPermissions(forceRefresh: false)
                return try .success(
                    id: request.id,
                    value: AppStatusResult(
                        running: true,
                        appVersion: MupawConstants.appVersion,
                        rpcProtocolVersion: MupawConstants.rpcProtocolVersion,
                        processID: ProcessInfo.processInfo.processIdentifier,
                        permissions: permissions
                    )
                )

            case .capabilitiesGet:
                return try .success(id: request.id, value: CapabilityCatalog.current)

            case .permissionsGet:
                refreshPermissions(forceRefresh: false)
                return try .success(id: request.id, value: permissions)

            case .sourcesList:
                refreshPermissions(forceRefresh: false)
                guard permissions.screenCapture == .authorized else {
                    return .failure(
                        id: request.id,
                        code: .permissionRequired,
                        message: "Grant Screen & System Audio Recording permission to Mupaw, then retry."
                    )
                }
                let result = try await captureService.listSources()
                sources = result.sources
                return try .success(id: request.id, value: result)

            case .screenshotCapture:
                refreshPermissions(forceRefresh: false)
                guard permissions.screenCapture == .authorized else {
                    return .failure(
                        id: request.id,
                        code: .permissionRequired,
                        message: "Grant Screen & System Audio Recording permission to Mupaw, then retry."
                    )
                }
                let captureRequest = try request.parameters.decode(ScreenshotRequest.self)
                let artifact = try await captureService.capture(captureRequest)
                lastArtifact = artifact
                return try .success(id: request.id, value: artifact)
            }
        } catch let error as CaptureServiceError {
            switch error {
            case .sourceNotFound:
                return .failure(id: request.id, code: .sourceNotFound, message: error.localizedDescription)
            case .invalidSourceSize:
                return .failure(id: request.id, code: .captureFailed, message: error.localizedDescription)
            }
        } catch let error as DecodingError {
            return .failure(id: request.id, code: .invalidRequest, message: error.localizedDescription)
        } catch {
            return .failure(id: request.id, code: .internalError, message: error.localizedDescription)
        }
    }
}
