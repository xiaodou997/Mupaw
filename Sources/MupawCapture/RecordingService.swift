@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MupawCore
@preconcurrency import ScreenCaptureKit

private func recordingLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func recordingLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: recordingLocalizedString(key), locale: Locale.current, arguments: arguments)
}

public enum RecordingServiceError: Error, LocalizedError, Sendable {
    case sourceRequired(ScreenshotCaptureMode)
    case sourceNotFound(String)
    case sourceKindMismatch(String, ScreenshotCaptureMode)
    case regionRequired
    case invalidRegion
    case crossDisplayRegionUnsupported
    case invalidFrameRate(Int)
    case invalidFormat
    case operationInProgress(String)
    case sessionNotFound(String)
    case sessionNotActive(String)
    case outputTooLarge
    case streamFailed(String)
    case writerFailed(String)
    case finalizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceRequired(let mode):
            recordingLocalizedFormat("recording.error.source_required.format", mode.rawValue)
        case .sourceNotFound(let identifier):
            recordingLocalizedFormat("recording.error.source_not_found.format", identifier)
        case .sourceKindMismatch(let identifier, let mode):
            recordingLocalizedFormat(
                "recording.error.source_kind_mismatch.format",
                identifier,
                mode.rawValue
            )
        case .regionRequired:
            recordingLocalizedString("recording.error.region_required")
        case .invalidRegion:
            recordingLocalizedString("recording.error.invalid_region")
        case .crossDisplayRegionUnsupported:
            recordingLocalizedString("recording.error.cross_display_region")
        case .invalidFrameRate(let value):
            recordingLocalizedFormat("recording.error.invalid_frame_rate.format", value)
        case .invalidFormat:
            recordingLocalizedString("recording.error.invalid_format")
        case .operationInProgress(let identifier):
            recordingLocalizedFormat("recording.error.operation_in_progress.format", identifier)
        case .sessionNotFound(let identifier):
            recordingLocalizedFormat("recording.error.session_not_found.format", identifier)
        case .sessionNotActive(let identifier):
            recordingLocalizedFormat("recording.error.session_not_active.format", identifier)
        case .outputTooLarge:
            recordingLocalizedString("recording.error.output_too_large")
        case .streamFailed(let message):
            recordingLocalizedFormat("recording.error.stream_failed.format", message)
        case .writerFailed(let message):
            recordingLocalizedFormat("recording.error.writer_failed.format", message)
        case .finalizationFailed(let message):
            recordingLocalizedFormat("recording.error.finalization_failed.format", message)
        }
    }
}

private final class RecordingStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onFailure: @Sendable (Error) -> Void

    init(onFailure: @escaping @Sendable (Error) -> Void) {
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error)
    }
}

@MainActor
public final class RecordingService {
    private final class ActiveRecording {
        let id: String
        let request: RecordingRequest
        let source: CaptureSourceDescriptor
        let resolution: RecordingResolution
        let stream: SCStream
        let streamDelegate: RecordingStreamDelegate
        let writer: RecordingFrameWriter
        let fileURL: URL
        let startedAt: Date
        var phase: RecordingPhase
        var watchdog: Task<Void, Never>?

        init(
            id: String,
            request: RecordingRequest,
            source: CaptureSourceDescriptor,
            resolution: RecordingResolution,
            stream: SCStream,
            streamDelegate: RecordingStreamDelegate,
            writer: RecordingFrameWriter,
            fileURL: URL,
            startedAt: Date,
            phase: RecordingPhase
        ) {
            self.id = id
            self.request = request
            self.source = source
            self.resolution = resolution
            self.stream = stream
            self.streamDelegate = streamDelegate
            self.writer = writer
            self.fileURL = fileURL
            self.startedAt = startedAt
            self.phase = phase
        }
    }

    private struct PreparedRecording {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let source: CaptureSourceDescriptor
        let resolution: RecordingResolution
    }

    private let paths: MupawPaths
    private let fileManager: FileManager
    private var active: ActiveRecording?
    private var terminalStatuses: [String: RecordingSessionStatus] = [:]
    private var terminalOrder: [String] = []

    public init(paths: MupawPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public var hasActiveRecording: Bool {
        active != nil
    }

    public var activeSessionID: String? {
        active?.id
    }

    public func startRecording(_ request: RecordingRequest) async throws -> RecordingSessionStatus {
        if let active {
            throw RecordingServiceError.operationInProgress(active.id)
        }
        try validate(request)
        try paths.prepare(fileManager: fileManager)

        let sessionID = UUID().uuidString.lowercased()
        let prepared = try await prepareRecording(request: request, sessionID: sessionID)
        let fileURL = uniqueRecordingURL(request: request)

        let writer: RecordingFrameWriter
        do {
            writer = try RecordingFrameWriter(
                outputURL: fileURL,
                pixelWidth: prepared.resolution.pixelWidth,
                pixelHeight: prepared.resolution.pixelHeight,
                frameRate: request.frameRate,
                quality: request.quality,
                includeSystemAudio: request.includeSystemAudio
            ) { [weak self] error in
                Task { @MainActor [weak self] in
                    await self?.failActiveRecording(sessionID: sessionID, error: error)
                }
            }
            try writer.prepare()
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw RecordingServiceError.writerFailed(error.localizedDescription)
        }

        let delegate = RecordingStreamDelegate { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.failActiveRecording(sessionID: sessionID, error: error)
            }
        }
        let stream = SCStream(
            filter: prepared.filter,
            configuration: prepared.configuration,
            delegate: delegate
        )
        do {
            try stream.addStreamOutput(
                writer,
                type: .screen,
                sampleHandlerQueue: writer.sampleQueue
            )
            if request.includeSystemAudio {
                try stream.addStreamOutput(
                    writer,
                    type: .audio,
                    sampleHandlerQueue: writer.sampleQueue
                )
            }
        } catch {
            await writer.cancelAndDelete()
            throw RecordingServiceError.streamFailed(error.localizedDescription)
        }

        let startedAt = Date()
        let active = ActiveRecording(
            id: sessionID,
            request: request,
            source: prepared.source,
            resolution: prepared.resolution,
            stream: stream,
            streamDelegate: delegate,
            writer: writer,
            fileURL: fileURL,
            startedAt: startedAt,
            phase: .starting
        )
        self.active = active

        do {
            try await stream.startCapture()
            active.phase = .recording
            active.watchdog = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(
                        for: .seconds(MupawConstants.maximumRecordingDurationSeconds)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = try? await self?.stopRecording(
                    RecordingSessionRequest(sessionID: sessionID)
                )
            }
            return status(for: active)
        } catch {
            self.active = nil
            await writer.cancelAndDelete()
            let status = terminalStatus(
                for: active,
                phase: .failed,
                errorMessage: error.localizedDescription
            )
            remember(status)
            throw RecordingServiceError.streamFailed(error.localizedDescription)
        }
    }

    public func recordingStatus(
        _ request: RecordingSessionRequest
    ) throws -> RecordingSessionStatus {
        if let active, active.id == request.sessionID {
            return status(for: active)
        }
        guard let status = terminalStatuses[request.sessionID] else {
            throw RecordingServiceError.sessionNotFound(request.sessionID)
        }
        return status
    }

    public func stopRecording(
        _ request: RecordingSessionRequest
    ) async throws -> RecordingSessionStatus {
        if let status = terminalStatuses[request.sessionID] {
            return status
        }
        guard let active, active.id == request.sessionID else {
            if self.active == nil {
                throw RecordingServiceError.sessionNotFound(request.sessionID)
            }
            throw RecordingServiceError.sessionNotActive(request.sessionID)
        }

        guard active.phase != .stopping else {
            return status(for: active)
        }

        active.phase = .stopping
        active.watchdog?.cancel()
        active.watchdog = nil

        do {
            try await active.stream.stopCapture()
            let metrics = try await active.writer.finish()
            let completedAt = Date()
            let artifact = try await RecordingArtifactEncoder.finalize(
                sessionID: active.id,
                source: active.source,
                request: active.request,
                fileURL: active.fileURL,
                expectedResolution: active.resolution,
                metrics: metrics,
                startedAt: active.startedAt,
                completedAt: completedAt
            )
            let status = RecordingSessionStatus(
                id: active.id,
                phase: .completed,
                source: active.source,
                format: active.request.format,
                codec: .h264,
                frameRate: active.request.frameRate,
                quality: active.request.quality,
                pixelWidth: active.resolution.pixelWidth,
                pixelHeight: active.resolution.pixelHeight,
                includeCursor: active.request.includeCursor,
                audio: artifact.audio,
                startedAt: active.startedAt,
                updatedAt: completedAt,
                elapsedDurationSeconds: artifact.durationSeconds,
                frameCount: artifact.frameCount,
                artifact: artifact
            )
            self.active = nil
            remember(status)
            return status
        } catch {
            await active.writer.cancelAndDelete()
            self.active = nil
            let status = terminalStatus(
                for: active,
                phase: .failed,
                errorMessage: error.localizedDescription
            )
            remember(status)
            throw RecordingServiceError.finalizationFailed(error.localizedDescription)
        }
    }

    public func cancelRecording(
        _ request: RecordingSessionRequest
    ) async throws -> RecordingSessionStatus {
        if let status = terminalStatuses[request.sessionID] {
            return status
        }
        guard let active, active.id == request.sessionID else {
            if self.active == nil {
                throw RecordingServiceError.sessionNotFound(request.sessionID)
            }
            throw RecordingServiceError.sessionNotActive(request.sessionID)
        }

        guard active.phase != .stopping else {
            return status(for: active)
        }

        active.phase = .stopping
        active.watchdog?.cancel()
        active.watchdog = nil
        try? await active.stream.stopCapture()
        await active.writer.cancelAndDelete()
        self.active = nil
        let status = terminalStatus(for: active, phase: .cancelled, errorMessage: nil)
        remember(status)
        return status
    }

    public func cancelActiveRecordingForShutdown() {
        guard let active else { return }
        active.watchdog?.cancel()
        active.writer.cancelAndDeleteImmediately()
        try? fileManager.removeItem(at: active.fileURL)
        Task {
            try? await active.stream.stopCapture()
        }
        self.active = nil
    }

    private func validate(_ request: RecordingRequest) throws {
        guard request.format == .mp4 else {
            throw RecordingServiceError.invalidFormat
        }
        guard MupawConstants.supportedRecordingFrameRates.contains(request.frameRate) else {
            throw RecordingServiceError.invalidFrameRate(request.frameRate)
        }
        switch request.mode {
        case .fullScreen:
            guard let sourceID = request.sourceID, !sourceID.isEmpty else {
                throw RecordingServiceError.sourceRequired(request.mode)
            }
            guard sourceID.hasPrefix("display:") else {
                throw RecordingServiceError.sourceKindMismatch(sourceID, request.mode)
            }
            guard request.region == nil else {
                throw RecordingServiceError.invalidRegion
            }
        case .window:
            guard let sourceID = request.sourceID, !sourceID.isEmpty else {
                throw RecordingServiceError.sourceRequired(request.mode)
            }
            guard sourceID.hasPrefix("window:") else {
                throw RecordingServiceError.sourceKindMismatch(sourceID, request.mode)
            }
            guard request.region == nil else {
                throw RecordingServiceError.invalidRegion
            }
        case .region:
            guard request.sourceID == nil else {
                throw RecordingServiceError.invalidRegion
            }
            guard let region = request.region,
                region.coordinateSpace == .globalDisplayPoints,
                region.rect.isFinite,
                region.rect.hasPositiveArea
            else {
                throw RecordingServiceError.regionRequired
            }
        }
    }

    private func prepareRecording(
        request: RecordingRequest,
        sessionID: String
    ) async throws -> PreparedRecording {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        switch request.mode {
        case .fullScreen:
            guard let sourceID = request.sourceID,
                let display = content.displays.first(where: {
                    "display:\($0.displayID)" == sourceID
                })
            else {
                throw RecordingServiceError.sourceNotFound(request.sourceID ?? "")
            }
            let filter = displayFilter(
                display,
                content: content,
                excludingMupawUI: request.excludeMupawUI
            )
            let sourceWidth = max(
                1,
                Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded(.up))
            )
            let sourceHeight = max(
                1,
                Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded(.up))
            )
            let resolution = try plannedResolution(width: sourceWidth, height: sourceHeight)
            let source = CaptureSourceDescriptor(
                id: sourceID,
                kind: .display,
                title: recordingLocalizedString("recording.source.display"),
                applicationName: nil,
                pixelWidth: resolution.pixelWidth,
                pixelHeight: resolution.pixelHeight,
                framePoints: captureRect(display.frame),
                pointPixelScale: Double(filter.pointPixelScale),
                isOnScreen: true,
                isPrimaryDisplay: display.displayID == CGMainDisplayID()
            )
            return PreparedRecording(
                filter: filter,
                configuration: streamConfiguration(
                    request: request,
                    resolution: resolution,
                    sourceRect: nil,
                    independentWindow: false
                ),
                source: source,
                resolution: resolution
            )

        case .window:
            guard let sourceID = request.sourceID,
                let window = content.windows.first(where: {
                    "window:\($0.windowID)" == sourceID && $0.isOnScreen
                })
            else {
                throw RecordingServiceError.sourceNotFound(request.sourceID ?? "")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let sourceWidth = max(
                1,
                Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded(.up))
            )
            let sourceHeight = max(
                1,
                Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded(.up))
            )
            let resolution = try plannedResolution(width: sourceWidth, height: sourceHeight)
            let application = window.owningApplication
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = CaptureSourceDescriptor(
                id: sourceID,
                kind: .window,
                title: title?.isEmpty == false
                    ? title!
                    : (application?.applicationName
                        ?? recordingLocalizedString("source.untitled_window")),
                applicationName: application?.applicationName,
                applicationBundleIdentifier: application?.bundleIdentifier,
                applicationProcessID: application?.processID,
                pixelWidth: resolution.pixelWidth,
                pixelHeight: resolution.pixelHeight,
                framePoints: captureRect(window.frame),
                pointPixelScale: Double(filter.pointPixelScale),
                isOnScreen: window.isOnScreen,
                isActive: window.isActive
            )
            return PreparedRecording(
                filter: filter,
                configuration: streamConfiguration(
                    request: request,
                    resolution: resolution,
                    sourceRect: nil,
                    independentWindow: true
                ),
                source: source,
                resolution: resolution
            )

        case .region:
            guard let region = request.region else {
                throw RecordingServiceError.regionRequired
            }
            let geometries = content.displays.map { display in
                let filter = SCContentFilter(display: display, excludingWindows: [])
                return CaptureDisplayGeometry(
                    sourceID: "display:\(display.displayID)",
                    framePoints: captureRect(display.frame),
                    pointPixelScale: max(1, Double(filter.pointPixelScale))
                )
            }
            let plan: RegionCapturePlan
            do {
                plan = try RegionCapturePlanner.makePlan(region: region, displays: geometries)
            } catch RegionCapturePlanningError.noDisplayIntersection {
                throw RecordingServiceError.invalidRegion
            } catch RegionCapturePlanningError.outputTooLarge {
                throw RecordingServiceError.outputTooLarge
            } catch {
                throw RecordingServiceError.invalidRegion
            }
            guard plan.slices.count == 1,
                let slice = plan.slices.first,
                slice.destinationPixelRect.x == 0,
                slice.destinationPixelRect.y == 0,
                slice.destinationPixelRect.width == plan.outputPixelWidth,
                slice.destinationPixelRect.height == plan.outputPixelHeight,
                let displayID = UInt32(slice.sourceID.dropFirst("display:".count)),
                let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                throw RecordingServiceError.crossDisplayRegionUnsupported
            }
            let resolution = try plannedResolution(
                width: plan.outputPixelWidth,
                height: plan.outputPixelHeight
            )
            let filter = displayFilter(
                display,
                content: content,
                excludingMupawUI: request.excludeMupawUI
            )
            let source = CaptureSourceDescriptor(
                id: "region:\(sessionID)",
                kind: .region,
                title: recordingLocalizedString("recording.source.region"),
                applicationName: nil,
                pixelWidth: resolution.pixelWidth,
                pixelHeight: resolution.pixelHeight,
                framePoints: region.rect.standardized,
                pointPixelScale: Double(resolution.pixelWidth) / region.rect.standardized.width,
                isOnScreen: true
            )
            return PreparedRecording(
                filter: filter,
                configuration: streamConfiguration(
                    request: request,
                    resolution: resolution,
                    sourceRect: cgRect(slice.sourceRectPoints),
                    independentWindow: false
                ),
                source: source,
                resolution: resolution
            )
        }
    }

    private func streamConfiguration(
        request: RecordingRequest,
        resolution: RecordingResolution,
        sourceRect: CGRect?,
        independentWindow: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = resolution.pixelWidth
        configuration.height = resolution.pixelHeight
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(request.frameRate)
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = request.includeCursor
        configuration.capturesAudio = request.includeSystemAudio
        configuration.sampleRate = MupawConstants.recordingSystemAudioSampleRate
        configuration.channelCount = MupawConstants.recordingSystemAudioChannelCount
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        if independentWindow {
            configuration.ignoreShadowsSingleWindow = true
        }
        return configuration
    }

    private func displayFilter(
        _ display: SCDisplay,
        content: SCShareableContent,
        excludingMupawUI: Bool
    ) -> SCContentFilter {
        if excludingMupawUI,
            let application = content.applications.first(where: {
                $0.bundleIdentifier == MupawConstants.appBundleIdentifier
            })
        {
            return SCContentFilter(
                display: display,
                excludingApplications: [application],
                exceptingWindows: []
            )
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private func plannedResolution(width: Int, height: Int) throws -> RecordingResolution {
        do {
            return try RecordingResolutionPlanner.makeResolution(
                sourcePixelWidth: width,
                sourcePixelHeight: height
            )
        } catch {
            throw RecordingServiceError.outputTooLarge
        }
    }

    private func status(for active: ActiveRecording, now: Date = Date()) -> RecordingSessionStatus {
        let metrics = active.writer.metricsSnapshot()
        return RecordingSessionStatus(
            id: active.id,
            phase: active.phase,
            source: active.source,
            format: active.request.format,
            codec: .h264,
            frameRate: active.request.frameRate,
            quality: active.request.quality,
            pixelWidth: active.resolution.pixelWidth,
            pixelHeight: active.resolution.pixelHeight,
            includeCursor: active.request.includeCursor,
            audio: audioInfo(for: active, metrics: metrics, phase: active.phase),
            startedAt: active.startedAt,
            updatedAt: now,
            elapsedDurationSeconds: max(
                max(metrics.durationSeconds, metrics.audioDurationSeconds),
                max(0, now.timeIntervalSince(active.startedAt))
            ),
            frameCount: metrics.frameCount
        )
    }

    private func terminalStatus(
        for active: ActiveRecording,
        phase: RecordingPhase,
        errorMessage: String?
    ) -> RecordingSessionStatus {
        let now = Date()
        let metrics = active.writer.metricsSnapshot()
        return RecordingSessionStatus(
            id: active.id,
            phase: phase,
            source: active.source,
            format: active.request.format,
            codec: .h264,
            frameRate: active.request.frameRate,
            quality: active.request.quality,
            pixelWidth: active.resolution.pixelWidth,
            pixelHeight: active.resolution.pixelHeight,
            includeCursor: active.request.includeCursor,
            audio: audioInfo(for: active, metrics: metrics, phase: phase),
            startedAt: active.startedAt,
            updatedAt: now,
            elapsedDurationSeconds: max(
                max(metrics.durationSeconds, metrics.audioDurationSeconds),
                max(0, now.timeIntervalSince(active.startedAt))
            ),
            frameCount: metrics.frameCount,
            errorMessage: errorMessage
        )
    }

    private func audioInfo(
        for active: ActiveRecording,
        metrics: RecordingFrameMetrics,
        phase: RecordingPhase
    ) -> RecordingAudioInfo {
        guard active.request.includeSystemAudio else { return .disabled }
        let state: RecordingAudioState =
            switch phase {
            case .starting, .recording, .stopping:
                metrics.audioSampleBufferCount > 0 ? .capturing : .waiting
            case .completed:
                .completed
            case .failed:
                .failed
            case .cancelled:
                .cancelled
            }
        return RecordingAudioInfo(
            requested: true,
            state: state,
            codec: .aac,
            trackCount: 0,
            sampleRate: metrics.audioSampleRate
                ?? MupawConstants.recordingSystemAudioSampleRate,
            channelCount: metrics.audioChannelCount
                ?? MupawConstants.recordingSystemAudioChannelCount,
            durationSeconds: metrics.audioSampleBufferCount > 0
                ? metrics.audioDurationSeconds
                : nil,
            sampleBufferCount: metrics.audioSampleBufferCount
        )
    }

    private func failActiveRecording(sessionID: String, error: Error) async {
        guard let active, active.id == sessionID, active.phase != .stopping else { return }
        active.phase = .stopping
        active.watchdog?.cancel()
        active.watchdog = nil
        try? await active.stream.stopCapture()
        await active.writer.cancelAndDelete()
        self.active = nil
        remember(
            terminalStatus(
                for: active,
                phase: .failed,
                errorMessage: error.localizedDescription
            )
        )
    }

    private func remember(_ status: RecordingSessionStatus) {
        terminalStatuses[status.id] = status
        terminalOrder.removeAll(where: { $0 == status.id })
        terminalOrder.append(status.id)
        while terminalOrder.count > MupawConstants.maximumRecordingHistoryCount {
            let removed = terminalOrder.removeFirst()
            terminalStatuses.removeValue(forKey: removed)
        }
    }

    private func uniqueRecordingURL(request: RecordingRequest, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fallback = "Mupaw-Recording-\(formatter.string(from: now))"
        let baseName = FileNameSanitizer.sanitizedBaseName(request.fileName, fallback: fallback)
        var candidate = paths.recordingsDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension("mp4")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = paths.recordingsDirectory
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }
        return candidate
    }

    private func captureRect(_ rect: CGRect) -> CaptureRect {
        CaptureRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func cgRect(_ rect: CaptureRect) -> CGRect {
        let value = rect.standardized
        return CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}
