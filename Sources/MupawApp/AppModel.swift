import AppKit
import Foundation
import MupawCapture
import MupawCore
import MupawEditing
import Observation

private enum AppCaptureError: Error, LocalizedError {
    case operationInProgress
    case permissionRequired
    case sourceRequired
    case noDisplayUnderPointer
    case noActiveWindow

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return L10n.string("capture.error.operation_in_progress")
        case .permissionRequired:
            return L10n.string("capture.error.permission_required")
        case .sourceRequired:
            return L10n.string("error.select_source")
        case .noDisplayUnderPointer:
            return L10n.string("capture.error.no_display_under_pointer")
        case .noActiveWindow:
            return L10n.string("capture.error.no_active_window")
        }
    }
}

enum AppWorkspaceMode: String, CaseIterable, Hashable {
    case screenshot
    case recording
}

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
    var selectedWorkspaceMode: AppWorkspaceMode = .screenshot
    var selectedCaptureMode: ScreenshotCaptureMode = .region {
        didSet { normalizeSelectedSource() }
    }
    var selectedSourceID: String?
    var includeCursor = false
    var recordingFrameRate = 30
    var recordingQuality: RecordingVideoQuality = .standard
    var recordingAudioSource: RecordingAudioSource = .none
    private(set) var microphoneDevices: [MicrophoneDeviceDescriptor] = []
    var selectedMicrophoneDeviceID: String?
    private(set) var currentRecordingStatus: RecordingSessionStatus?
    private(set) var lastRecordingArtifact: RecordingArtifact?
    private(set) var lastArtifact: ScreenshotArtifact?
    private(set) var activeProject: ScreenshotProjectState?
    private(set) var activeProjectPreview: ProjectPreviewResult?
    private(set) var lastProjectExport: ProjectExportArtifact?
    private(set) var lastOCRResult: ProjectOCRResult?
    private(set) var lastColorSample: ProjectColorSampleResult?
    var selectedOCRObservationID: String?
    private(set) var isPointColorSampling = false
    var selectedEditObjectID: String?
    private(set) var rpcStatus = L10n.string("rpc.not_started")
    private(set) var isBusy = false
    private(set) var isSelectingRegion = false
    private(set) var hotKeyRegistrations: [GlobalHotKeyRegistration] = []
    var errorMessage: String?

    var hasActiveRecording: Bool {
        currentRecordingStatus?.phase.isActive == true || recordingService.hasActiveRecording
    }

    var captureSources: [CaptureSourceDescriptor] {
        switch selectedCaptureMode {
        case .fullScreen:
            return sources.filter { $0.kind == .display }
        case .window:
            return sources.filter { $0.kind == .window }
        case .region:
            return []
        }
    }

    var selectedEditObject: ScreenshotEditObject? {
        guard let selectedEditObjectID else { return nil }
        return activeProject?.content.objects.first(where: { $0.id == selectedEditObjectID })
    }

    var selectedOCRObservation: OCRTextObservation? {
        guard let selectedOCRObservationID else { return nil }
        return lastOCRResult?.observations.first(where: { $0.id == selectedOCRObservationID })
    }

    private let paths: MupawPaths
    private let captureService: CaptureService
    private let recordingService: RecordingService
    private let projectService: ScreenshotProjectService
    private let permissionService = PermissionService()
    private let microphoneDeviceService: MicrophoneDeviceService
    private let regionSelectionController = RegionSelectionController()
    private var rpcServer: AgentRPCServer?
    private var hotKeyManager: GlobalHotKeyManager?
    private var workspaceObserver: NSObjectProtocol?
    private var lastExternalApplicationProcessID: Int32?
    private var hasStarted = false
    private var recordingStatusTask: Task<Void, Never>?

    init() {
        do {
            let paths = try MupawPaths.live()
            self.paths = paths
            self.captureService = CaptureService(paths: paths)
            let microphoneDeviceService = MicrophoneDeviceService()
            self.microphoneDeviceService = microphoneDeviceService
            self.recordingService = RecordingService(
                paths: paths,
                microphoneDeviceService: microphoneDeviceService
            )
            self.projectService = ScreenshotProjectService(
                paths: paths,
                textRecognizer: IsolatedVisionScreenshotTextRecognizer()
            )
        } catch {
            let fallback = MupawPaths(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Mupaw", isDirectory: true)
            )
            self.paths = fallback
            self.captureService = CaptureService(paths: fallback)
            let microphoneDeviceService = MicrophoneDeviceService()
            self.microphoneDeviceService = microphoneDeviceService
            self.recordingService = RecordingService(
                paths: fallback,
                microphoneDeviceService: microphoneDeviceService
            )
            self.projectService = ScreenshotProjectService(
                paths: fallback,
                textRecognizer: IsolatedVisionScreenshotTextRecognizer()
            )
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
        refreshMicrophoneDevices(showErrors: false)
        startTrackingExternalApplications()
        startGlobalHotKeys()

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
            await refreshSources(showErrors: false)
        }
    }

    func shutdown() {
        recordingStatusTask?.cancel()
        recordingStatusTask = nil
        recordingService.cancelActiveRecordingForShutdown()
        regionSelectionController.cancel()
        hotKeyManager?.stop()
        hotKeyManager = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
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
        if permissions.screenCapture == .authorized {
            Task { await refreshSources(showErrors: false) }
        }
    }

    func requestMicrophonePermission() async {
        _ = await permissionService.requestMicrophoneAccess()
        refreshPermissions()
        refreshMicrophoneDevices(showErrors: false)
    }

    func refreshMicrophoneDevices(showErrors: Bool = true) {
        let result = microphoneDeviceService.listDevices()
        microphoneDevices = result.devices
        if let selectedMicrophoneDeviceID,
            microphoneDevices.contains(where: { $0.id == selectedMicrophoneDeviceID })
        {
            return
        }
        selectedMicrophoneDeviceID =
            result.defaultDeviceID
            ?? microphoneDevices.first(where: { $0.isDefault })?.id
            ?? microphoneDevices.first?.id
        if showErrors, recordingAudioSource == .microphone, microphoneDevices.isEmpty {
            errorMessage = L10n.string("recording.error.no_microphone_devices")
        }
    }

    func openMicrophonePrivacySettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshSources(showErrors: Bool = true) async {
        guard !isBusy else { return }
        do {
            let result = try await captureService.listSources(forceRefresh: true)
            sources = result.sources
            normalizeSelectedSource()
        } catch {
            if showErrors {
                errorMessage = localizedMessage(for: error)
            }
            refreshPermissions()
        }
    }

    func captureSelectedMode() async {
        await performCapture {
            switch selectedCaptureMode {
            case .region:
                return try await captureInteractiveRegionArtifact()
            case .fullScreen, .window:
                guard let selectedSourceID else {
                    throw AppCaptureError.sourceRequired
                }
                return try await captureService.capture(
                    ScreenshotRequest(
                        mode: selectedCaptureMode,
                        sourceID: selectedSourceID,
                        includeCursor: includeCursor,
                        excludeMupawUI: selectedCaptureMode == .fullScreen
                    )
                )
            }
        }
    }

    func selectEditObject(_ objectID: String?) {
        selectedEditObjectID = objectID
    }

    func addArrowEdit() async {
        guard let project = activeProject else { return }
        let visible = project.visibleBounds
        let arrow = ArrowEdit(
            start: ImagePixelPoint(
                x: visible.minX + visible.width * 0.20,
                y: visible.minY + visible.height * 0.42
            ),
            end: ImagePixelPoint(
                x: visible.minX + visible.width * 0.80,
                y: visible.minY + visible.height * 0.58
            )
        )
        await applyActiveProjectCommands([.addObject(.arrow(arrow))], selectAfter: arrow.id)
    }

    func addTextEdit() async {
        guard let project = activeProject else { return }
        let visible = project.visibleBounds
        let frame = ImagePixelRect(
            x: visible.minX + visible.width * 0.22,
            y: visible.minY + visible.height * 0.36,
            width: max(80, visible.width * 0.56),
            height: max(36, visible.height * 0.16)
        ).clamped(to: project.originalBounds, minimumSize: MupawConstants.minimumEditorObjectSize)
        let text = TextEdit(
            frame: frame,
            text: L10n.string("editor.default_text"),
            fontSize: min(64, max(18, visible.height * 0.08))
        )
        await applyActiveProjectCommands([.addObject(.text(text))], selectAfter: text.id)
    }

    func addMosaicEdit() async {
        guard let project = activeProject else { return }
        let visible = project.visibleBounds
        let frame = ImagePixelRect(
            x: visible.minX + visible.width * 0.34,
            y: visible.minY + visible.height * 0.35,
            width: max(60, visible.width * 0.32),
            height: max(40, visible.height * 0.24)
        ).clamped(to: project.originalBounds, minimumSize: MupawConstants.minimumEditorObjectSize)
        let mosaic = MosaicEdit(frame: frame, blockSize: 18)
        await applyActiveProjectCommands([.addObject(.mosaic(mosaic))], selectAfter: mosaic.id)
    }

    func updateEditObject(_ object: ScreenshotEditObject) async {
        await applyActiveProjectCommands([.updateObject(object)], selectAfter: object.id)
    }

    func deleteSelectedEditObject() async {
        guard let selectedEditObjectID else { return }
        await applyActiveProjectCommands([.deleteObject(selectedEditObjectID)], selectAfter: nil)
    }

    func setProjectCrop(_ rect: ImagePixelRect?) async {
        await applyActiveProjectCommands([.setCrop(rect)], selectAfter: nil)
    }

    func setVisualStyle(_ style: ScreenshotVisualStyle) async {
        await applyActiveProjectCommands([.setVisualStyle(style)], selectAfter: nil)
    }

    func applyStylePreset(_ preset: ScreenshotStylePreset) async {
        await applyActiveProjectCommands([.applyStylePreset(preset)], selectAfter: nil)
    }

    func clearVisualStyle() async {
        await applyActiveProjectCommands([.clearVisualStyle], selectAfter: nil)
    }

    func resetActiveProject() async {
        await applyActiveProjectCommands([.reset], selectAfter: nil)
    }

    func undoActiveProject() async {
        await performActiveProjectHistory(.undo)
    }

    func redoActiveProject() async {
        await performActiveProjectHistory(.redo)
    }

    func exportActiveProject() async {
        guard let project = activeProject, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            lastProjectExport = try await projectService.exportProject(
                ProjectExportRequest(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    fileName: project.title
                )
            )
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func runOCR() async {
        guard let project = activeProject, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await projectService.recognizeText(
                ProjectOCRRequest(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    recognitionLevel: .accurate,
                    usesLanguageCorrection: true
                )
            )
            lastOCRResult = result
            selectedOCRObservationID = result.observations.first?.id
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func clearOCRResult() {
        lastOCRResult = nil
        selectedOCRObservationID = nil
    }

    func selectOCRObservation(_ observationID: String?) {
        selectedOCRObservationID = observationID
    }

    func copyOCRTextToPasteboard() {
        guard let text = lastOCRResult?.fullText, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyOCRObservationToPasteboard(_ observationID: String) {
        guard let text = lastOCRResult?.observations.first(where: { $0.id == observationID })?.text,
            !text.isEmpty
        else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func togglePointColorSampling() {
        isPointColorSampling.toggle()
        if isPointColorSampling {
            selectedEditObjectID = nil
        }
    }

    func cancelPointColorSampling() {
        isPointColorSampling = false
    }

    func sampleColor(at point: ImagePixelPoint) async {
        guard let project = activeProject, !isBusy else { return }
        isPointColorSampling = false
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            lastColorSample = try await projectService.sampleColor(
                ProjectColorSampleRequest(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    mode: .point,
                    point: point
                )
            )
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func sampleColor(in region: ImagePixelRect) async {
        guard let project = activeProject, !isBusy else { return }
        isPointColorSampling = false
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            lastColorSample = try await projectService.sampleColor(
                ProjectColorSampleRequest(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    mode: .region,
                    region: region
                )
            )
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func clearColorSample() {
        lastColorSample = nil
        isPointColorSampling = false
    }

    func startSelectedRecording() async {
        guard !isBusy, !recordingService.hasActiveRecording else {
            NSSound.beep()
            errorMessage = L10n.string("recording.error.operation_in_progress.short")
            return
        }
        guard permissions.screenCapture == .authorized else {
            errorMessage = AppCaptureError.permissionRequired.localizedDescription
            return
        }
        if recordingAudioSource == .microphone {
            guard permissions.microphone == .authorized else {
                errorMessage = L10n.string("recording.error.microphone_permission_required")
                return
            }
            refreshMicrophoneDevices(showErrors: false)
            guard selectedMicrophoneDeviceID != nil else {
                errorMessage = L10n.string("recording.error.no_microphone_devices")
                return
            }
        }

        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            isSelectingRegion = false
        }

        do {
            let region: CaptureRegion?
            if selectedCaptureMode == .region {
                isSelectingRegion = true
                region = try await regionSelectionController.selectRegion()
                isSelectingRegion = false
                try await Task.sleep(for: .milliseconds(120))
            } else {
                region = nil
            }

            let sourceID: String?
            if selectedCaptureMode == .region {
                sourceID = nil
            } else {
                guard let selectedSourceID else {
                    throw AppCaptureError.sourceRequired
                }
                sourceID = selectedSourceID
            }

            let status = try await recordingService.startRecording(
                RecordingRequest(
                    mode: selectedCaptureMode,
                    sourceID: sourceID,
                    region: region,
                    frameRate: recordingFrameRate,
                    quality: recordingQuality,
                    includeCursor: includeCursor,
                    audioSource: recordingAudioSource,
                    microphoneDeviceID: recordingAudioSource == .microphone
                        ? selectedMicrophoneDeviceID
                        : nil,
                    excludeMupawUI: selectedCaptureMode != .window
                )
            )
            selectedWorkspaceMode = .recording
            applyRecordingStatus(status)
        } catch let error as RegionSelectionError where error == .cancelled {
            errorMessage = nil
        } catch {
            errorMessage = localizedMessage(for: error)
            refreshPermissions()
        }
    }

    func stopCurrentRecording() async {
        guard let sessionID = currentRecordingStatus?.id ?? recordingService.activeSessionID,
            !isBusy
        else {
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let status = try await recordingService.stopRecording(
                RecordingSessionRequest(sessionID: sessionID)
            )
            applyRecordingStatus(status)
        } catch {
            errorMessage = localizedMessage(for: error)
            if let status = try? recordingService.recordingStatus(
                RecordingSessionRequest(sessionID: sessionID)
            ) {
                applyRecordingStatus(status)
            }
        }
    }

    func cancelCurrentRecording() async {
        guard let sessionID = currentRecordingStatus?.id ?? recordingService.activeSessionID,
            !isBusy
        else {
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let status = try await recordingService.cancelRecording(
                RecordingSessionRequest(sessionID: sessionID)
            )
            applyRecordingStatus(status)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func retryGlobalHotKeys() {
        hotKeyRegistrations = hotKeyManager?.start() ?? []
    }

    private func performCapture(
        _ operation: () async throws -> ScreenshotArtifact
    ) async {
        guard !isBusy, !recordingService.hasActiveRecording else {
            NSSound.beep()
            errorMessage = AppCaptureError.operationInProgress.localizedDescription
            return
        }
        guard permissions.screenCapture == .authorized else {
            errorMessage = AppCaptureError.permissionRequired.localizedDescription
            return
        }

        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            isSelectingRegion = false
        }

        do {
            let artifact = try await operation()
            lastArtifact = artifact
            try await createAndActivateProject(from: artifact)
        } catch let error as RegionSelectionError where error == .cancelled {
            errorMessage = nil
        } catch {
            errorMessage = localizedMessage(for: error)
            refreshPermissions()
            if error is CaptureServiceError {
                await refreshSourceStateAfterCaptureFailure()
            }
        }
    }

    private func createAndActivateProject(from artifact: ScreenshotArtifact) async throws {
        let state = try await projectService.createProject(
            ProjectCreateRequest(
                sourceFileURL: artifact.fileURL,
                sourceSHA256: artifact.sha256,
                sourceArtifactID: artifact.id,
                title: artifact.source.title
            )
        )
        activeProject = state
        selectedEditObjectID = nil
        clearAnalysisState()
        activeProjectPreview = try await projectService.previewProject(
            ProjectPreviewRequest(projectID: state.id, expectedRevision: state.revision)
        )
    }

    private func applyActiveProjectCommands(
        _ commands: [ProjectEditCommand],
        selectAfter: String?
    ) async {
        guard let project = activeProject, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let state = try await projectService.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    commands: commands
                )
            )
            activeProject = state
            selectedEditObjectID = selectAfter
            clearAnalysisState()
            activeProjectPreview = try await projectService.previewProject(
                ProjectPreviewRequest(projectID: state.id, expectedRevision: state.revision)
            )
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    private func performActiveProjectHistory(_ action: ProjectHistoryAction) async {
        guard let project = activeProject, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let state = try await projectService.performHistory(
                ProjectHistoryRequest(
                    projectID: project.id,
                    expectedRevision: project.revision,
                    action: action
                )
            )
            activeProject = state
            clearAnalysisState()
            if let selectedEditObjectID,
                !state.content.objects.contains(where: { $0.id == selectedEditObjectID })
            {
                self.selectedEditObjectID = nil
            }
            activeProjectPreview = try await projectService.previewProject(
                ProjectPreviewRequest(projectID: state.id, expectedRevision: state.revision)
            )
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    private func syncActiveProject(_ state: ScreenshotProjectState) async {
        guard activeProject?.id == state.id || activeProject == nil else { return }
        let previousIdentity = activeProject.map { ($0.id, $0.revision) }
        activeProject = state
        if previousIdentity?.0 != state.id || previousIdentity?.1 != state.revision {
            clearAnalysisState()
        }
        if let selectedEditObjectID,
            !state.content.objects.contains(where: { $0.id == selectedEditObjectID })
        {
            self.selectedEditObjectID = nil
        }
        activeProjectPreview = try? await projectService.previewProject(
            ProjectPreviewRequest(projectID: state.id, expectedRevision: state.revision)
        )
    }

    private func clearAnalysisState() {
        lastOCRResult = nil
        lastColorSample = nil
        selectedOCRObservationID = nil
        isPointColorSampling = false
    }

    private func applyRecordingStatus(_ status: RecordingSessionStatus) {
        currentRecordingStatus = status
        if let artifact = status.artifact {
            lastRecordingArtifact = artifact
        }
        if status.phase.isActive {
            startRecordingStatusUpdates(sessionID: status.id)
        } else {
            recordingStatusTask?.cancel()
            recordingStatusTask = nil
        }
    }

    private func startRecordingStatusUpdates(sessionID: String) {
        if recordingStatusTask != nil { return }
        recordingStatusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self else { return }
                do {
                    let status = try self.recordingService.recordingStatus(
                        RecordingSessionRequest(sessionID: sessionID)
                    )
                    self.applyRecordingStatus(status)
                    if !status.phase.isActive { return }
                } catch {
                    self.recordingStatusTask = nil
                    return
                }
            }
        }
    }

    private func captureInteractiveRegionArtifact() async throws -> ScreenshotArtifact {
        isSelectingRegion = true
        let region = try await regionSelectionController.selectRegion()
        isSelectingRegion = false
        try await Task.sleep(for: .milliseconds(120))
        return try await captureService.capture(
            ScreenshotRequest(
                mode: .region,
                region: region,
                includeCursor: includeCursor,
                excludeMupawUI: true
            )
        )
    }

    private func captureDisplayUnderPointer() async {
        await performCapture {
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                let displayID = displayID(for: screen)
            else {
                throw AppCaptureError.noDisplayUnderPointer
            }
            let result = try await captureService.listSources(forceRefresh: true)
            sources = result.sources
            normalizeSelectedSource()
            return try await captureService.capture(
                ScreenshotRequest(
                    mode: .fullScreen,
                    sourceID: "display:\(displayID)",
                    includeCursor: includeCursor,
                    excludeMupawUI: true
                )
            )
        }
    }

    private func captureFrontmostWindow() async {
        await performCapture {
            let application = NSWorkspace.shared.frontmostApplication
            let preferredProcessID: Int32?
            if application?.bundleIdentifier == MupawConstants.appBundleIdentifier {
                preferredProcessID = lastExternalApplicationProcessID
            } else {
                preferredProcessID = application?.processIdentifier
            }
            guard let preferredProcessID else {
                throw AppCaptureError.noActiveWindow
            }

            let result = try await captureService.listSources(forceRefresh: true)
            sources = result.sources
            normalizeSelectedSource()
            let candidates = result.sources.filter {
                $0.kind == .window
                    && $0.applicationProcessID == preferredProcessID
                    && $0.isOnScreen
            }
            let selected = frontmostWindowSource(
                from: candidates,
                processID: preferredProcessID
            )
            guard let selected else {
                throw AppCaptureError.noActiveWindow
            }
            return try await captureService.capture(
                ScreenshotRequest(
                    mode: .window,
                    sourceID: selected.id,
                    includeCursor: includeCursor,
                    excludeMupawUI: false
                )
            )
        }
    }

    private func frontmostWindowSource(
        from candidates: [CaptureSourceDescriptor],
        processID: Int32
    ) -> CaptureSourceDescriptor? {
        let candidatesByWindowID = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { source -> (CGWindowID, CaptureSourceDescriptor)? in
                guard source.id.hasPrefix("window:"),
                    let value = UInt32(source.id.dropFirst("window:".count))
                else {
                    return nil
                }
                return (CGWindowID(value), source)
            }
        )
        guard !candidatesByWindowID.isEmpty else { return nil }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        {
            for entry in windowInfo {
                guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                    ownerPID == processID,
                    let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                    let source = candidatesByWindowID[CGWindowID(windowNumber)]
                else {
                    continue
                }
                return source
            }
        }

        return candidates.first(where: { $0.isActive == true }) ?? candidates.first
    }

    private func normalizeSelectedSource() {
        let candidates = captureSources
        guard !candidates.isEmpty else {
            selectedSourceID = nil
            return
        }
        if let selectedSourceID,
            candidates.contains(where: { $0.id == selectedSourceID })
        {
            return
        }
        switch selectedCaptureMode {
        case .fullScreen:
            selectedSourceID =
                candidates.first(where: { $0.isPrimaryDisplay == true })?.id
                ?? candidates.first?.id
        case .window:
            selectedSourceID =
                candidates.first(where: { $0.isActive == true })?.id
                ?? candidates.first?.id
        case .region:
            selectedSourceID = nil
        }
    }

    private func startGlobalHotKeys() {
        let manager = GlobalHotKeyManager { [weak self] shortcut in
            guard let self else { return }
            Task { @MainActor in
                await self.handleGlobalShortcut(shortcut)
            }
        }
        hotKeyManager = manager
        hotKeyRegistrations = manager.start()
    }

    private func handleGlobalShortcut(_ shortcut: GlobalCaptureShortcut) async {
        switch shortcut {
        case .fullScreen:
            await captureDisplayUnderPointer()
        case .window:
            await captureFrontmostWindow()
        case .region:
            selectedCaptureMode = .region
            await captureSelectedMode()
        }
    }

    private func startTrackingExternalApplications() {
        if let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier != MupawConstants.appBundleIdentifier
        {
            lastExternalApplicationProcessID = application.processIdentifier
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                application.bundleIdentifier != MupawConstants.appBundleIdentifier
            else {
                return
            }
            Task { @MainActor in
                self?.lastExternalApplicationProcessID = application.processIdentifier
            }
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private func refreshSourceStateAfterCaptureFailure() async {
        if let result = try? await captureService.listSources(forceRefresh: true) {
            sources = result.sources
            normalizeSelectedSource()
        }
    }

    private func localizedMessage(for error: Error) -> String {
        if let description = error as? LocalizedError,
            let errorDescription = description.errorDescription
        {
            return errorDescription
        }
        return error.localizedDescription
    }

    private func rpcFailure(
        requestID: String,
        error: ScreenshotProjectServiceError
    ) -> AgentRPCResponse {
        switch error {
        case .artifactNotFound:
            return .failure(id: requestID, code: .artifactNotFound, message: error.localizedDescription)
        case .artifactHashMismatch:
            return .failure(
                id: requestID,
                code: .artifactHashMismatch,
                message: error.localizedDescription
            )
        case .projectNotFound:
            return .failure(id: requestID, code: .projectNotFound, message: error.localizedDescription)
        case .versionConflict(let expected, let actual):
            return .failure(
                id: requestID,
                code: .projectVersionConflict,
                message: error.localizedDescription,
                details: .object([
                    "expected_revision": .integer(expected),
                    "actual_revision": .integer(actual),
                ])
            )
        case .historyUnavailable:
            return .failure(
                id: requestID,
                code: .historyUnavailable,
                message: error.localizedDescription
            )
        case .invalidSourceURL, .sourceOutsideCaptureDirectory, .invalidProjectID,
            .invalidProjectData, .unsupportedImage, .canvasTooLarge, .invalidEdit:
            return .failure(id: requestID, code: .invalidEdit, message: error.localizedDescription)
        case .invalidAnalysis:
            return .failure(id: requestID, code: .invalidRequest, message: error.localizedDescription)
        case .ocrFailed:
            return .failure(id: requestID, code: .ocrFailed, message: error.localizedDescription)
        case .colorSamplingFailed:
            return .failure(
                id: requestID,
                code: .colorSamplingFailed,
                message: error.localizedDescription
            )
        case .renderFailed:
            return .failure(id: requestID, code: .internalError, message: error.localizedDescription)
        case .exportFailed:
            return .failure(id: requestID, code: .exportFailed, message: error.localizedDescription)
        }
    }

    private func rpcFailure(
        requestID: String,
        error: CaptureServiceError
    ) -> AgentRPCResponse {
        switch error {
        case .sourceNotFound:
            return .failure(
                id: requestID,
                code: .sourceNotFound,
                message: error.localizedDescription
            )
        case .sourceRequired, .sourceKindMismatch:
            return .failure(
                id: requestID,
                code: .invalidRequest,
                message: error.localizedDescription
            )
        case .regionRequired, .invalidRegion, .regionOutsideDisplays:
            return .failure(
                id: requestID,
                code: .invalidRegion,
                message: error.localizedDescription
            )
        case .invalidSourceSize, .regionTooLarge, .regionCompositionFailed:
            return .failure(
                id: requestID,
                code: .captureFailed,
                message: error.localizedDescription
            )
        }
    }

    private func rpcFailure(
        requestID: String,
        error: RecordingServiceError
    ) -> AgentRPCResponse {
        switch error {
        case .sourceNotFound:
            return .failure(
                id: requestID,
                code: .sourceNotFound,
                message: error.localizedDescription
            )
        case .operationInProgress(let sessionID):
            return .failure(
                id: requestID,
                code: .recordingInProgress,
                message: error.localizedDescription,
                details: .object(["session_id": .string(sessionID)])
            )
        case .audioMixingNotSupported:
            return .failure(
                id: requestID,
                code: .audioMixingNotSupported,
                message: error.localizedDescription
            )
        case .microphonePermissionRequired:
            return .failure(
                id: requestID,
                code: .microphonePermissionRequired,
                message: error.localizedDescription
            )
        case .microphoneDeviceNotFound:
            return .failure(
                id: requestID,
                code: .microphoneDeviceNotFound,
                message: error.localizedDescription
            )
        case .microphoneDisconnected:
            return .failure(
                id: requestID,
                code: .recordingFailed,
                message: error.localizedDescription
            )
        case .sessionNotFound:
            return .failure(
                id: requestID,
                code: .recordingNotFound,
                message: error.localizedDescription
            )
        case .sessionNotActive:
            return .failure(
                id: requestID,
                code: .recordingNotActive,
                message: error.localizedDescription
            )
        case .sourceRequired, .sourceKindMismatch, .regionRequired, .invalidRegion,
            .crossDisplayRegionUnsupported, .invalidFrameRate, .invalidFormat, .outputTooLarge:
            return .failure(
                id: requestID,
                code: .invalidRequest,
                message: error.localizedDescription
            )
        case .streamFailed, .writerFailed, .finalizationFailed:
            return .failure(
                id: requestID,
                code: .recordingFailed,
                message: error.localizedDescription
            )
        }
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
                normalizeSelectedSource()
                return try .success(id: request.id, value: result)

            case .microphonesList:
                refreshPermissions(forceRefresh: false)
                let result = microphoneDeviceService.listDevices()
                microphoneDevices = result.devices
                if selectedMicrophoneDeviceID == nil {
                    selectedMicrophoneDeviceID = result.defaultDeviceID ?? result.devices.first?.id
                }
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
                guard !isBusy, !recordingService.hasActiveRecording else {
                    return .failure(
                        id: request.id,
                        code: .captureInProgress,
                        message: "Another Mupaw capture or recording operation is already in progress."
                    )
                }
                isBusy = true
                defer { isBusy = false }
                let captureRequest = try request.parameters.decode(ScreenshotRequest.self)
                let artifact = try await captureService.capture(captureRequest)
                lastArtifact = artifact
                return try .success(id: request.id, value: artifact)

            case .recordingStart:
                refreshPermissions(forceRefresh: false)
                guard permissions.screenCapture == .authorized else {
                    return .failure(
                        id: request.id,
                        code: .permissionRequired,
                        message: "Grant Screen & System Audio Recording permission to Mupaw, then retry."
                    )
                }
                guard !isBusy else {
                    return .failure(
                        id: request.id,
                        code: .captureInProgress,
                        message: "Another Mupaw capture operation is already in progress."
                    )
                }
                isBusy = true
                defer { isBusy = false }
                let recordingRequest = try request.parameters.decode(RecordingRequest.self)
                let status = try await recordingService.startRecording(recordingRequest)
                selectedWorkspaceMode = .recording
                applyRecordingStatus(status)
                return try .success(id: request.id, value: status)

            case .recordingStatus:
                let sessionRequest = try request.parameters.decode(RecordingSessionRequest.self)
                let status = try recordingService.recordingStatus(sessionRequest)
                applyRecordingStatus(status)
                return try .success(id: request.id, value: status)

            case .recordingStop:
                guard !isBusy else {
                    return .failure(
                        id: request.id,
                        code: .captureInProgress,
                        message: "Mupaw is already finalizing another operation."
                    )
                }
                isBusy = true
                defer { isBusy = false }
                let sessionRequest = try request.parameters.decode(RecordingSessionRequest.self)
                let status = try await recordingService.stopRecording(sessionRequest)
                applyRecordingStatus(status)
                return try .success(id: request.id, value: status)

            case .recordingCancel:
                guard !isBusy else {
                    return .failure(
                        id: request.id,
                        code: .captureInProgress,
                        message: "Mupaw is already finalizing another operation."
                    )
                }
                isBusy = true
                defer { isBusy = false }
                let sessionRequest = try request.parameters.decode(RecordingSessionRequest.self)
                let status = try await recordingService.cancelRecording(sessionRequest)
                applyRecordingStatus(status)
                return try .success(id: request.id, value: status)

            case .projectCreate:
                let createRequest = try request.parameters.decode(ProjectCreateRequest.self)
                let state = try await projectService.createProject(createRequest)
                await syncActiveProject(state)
                return try .success(id: request.id, value: state)

            case .projectGet:
                let getRequest = try request.parameters.decode(ProjectGetRequest.self)
                let state = try await projectService.getProject(getRequest)
                return try .success(id: request.id, value: state)

            case .projectApplyEdits:
                let applyRequest = try request.parameters.decode(ProjectApplyEditsRequest.self)
                let state = try await projectService.applyEdits(applyRequest)
                await syncActiveProject(state)
                return try .success(id: request.id, value: state)

            case .projectHistory:
                let historyRequest = try request.parameters.decode(ProjectHistoryRequest.self)
                let state = try await projectService.performHistory(historyRequest)
                await syncActiveProject(state)
                return try .success(id: request.id, value: state)

            case .projectPreview:
                let previewRequest = try request.parameters.decode(ProjectPreviewRequest.self)
                let result = try await projectService.previewProject(previewRequest)
                return try .success(id: request.id, value: result)

            case .projectExport:
                let exportRequest = try request.parameters.decode(ProjectExportRequest.self)
                let result = try await projectService.exportProject(exportRequest)
                lastProjectExport = result
                return try .success(id: request.id, value: result)

            case .projectOCR:
                let ocrRequest = try request.parameters.decode(ProjectOCRRequest.self)
                let result = try await projectService.recognizeText(ocrRequest)
                if activeProject?.id == result.projectID {
                    lastOCRResult = result
                    selectedOCRObservationID = result.observations.first?.id
                }
                return try .success(id: request.id, value: result)

            case .projectColorSample:
                let colorRequest = try request.parameters.decode(ProjectColorSampleRequest.self)
                let result = try await projectService.sampleColor(colorRequest)
                if activeProject?.id == result.projectID {
                    lastColorSample = result
                    isPointColorSampling = false
                }
                return try .success(id: request.id, value: result)
            }
        } catch let error as ScreenshotProjectServiceError {
            return rpcFailure(requestID: request.id, error: error)
        } catch let error as CaptureServiceError {
            return rpcFailure(requestID: request.id, error: error)
        } catch let error as RecordingServiceError {
            return rpcFailure(requestID: request.id, error: error)
        } catch let error as DecodingError {
            return .failure(id: request.id, code: .invalidRequest, message: error.localizedDescription)
        } catch {
            return .failure(id: request.id, code: .internalError, message: error.localizedDescription)
        }
    }
}
