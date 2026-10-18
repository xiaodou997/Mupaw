import CoreGraphics
import Foundation
import MupawCore
@preconcurrency import ScreenCaptureKit

private func captureLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func captureLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: captureLocalizedString(key), locale: Locale.current, arguments: arguments)
}

public enum CaptureServiceError: Error, LocalizedError {
    case sourceRequired(ScreenshotCaptureMode)
    case sourceNotFound(String)
    case sourceKindMismatch(String, ScreenshotCaptureMode)
    case invalidSourceSize(String)
    case regionRequired
    case invalidRegion
    case regionOutsideDisplays
    case regionTooLarge
    case regionCompositionFailed

    public var errorDescription: String? {
        switch self {
        case .sourceRequired(let mode):
            return captureLocalizedFormat("capture.error.source_required.format", mode.rawValue)
        case .sourceNotFound(let identifier):
            return captureLocalizedFormat("capture.error.source_not_found.format", identifier)
        case .sourceKindMismatch(let identifier, let mode):
            return captureLocalizedFormat(
                "capture.error.source_kind_mismatch.format",
                identifier,
                mode.rawValue
            )
        case .invalidSourceSize(let identifier):
            return captureLocalizedFormat("capture.error.invalid_source_size.format", identifier)
        case .regionRequired:
            return captureLocalizedString("capture.error.region_required")
        case .invalidRegion:
            return captureLocalizedString("capture.error.invalid_region")
        case .regionOutsideDisplays:
            return captureLocalizedString("capture.error.region_outside_displays")
        case .regionTooLarge:
            return captureLocalizedString("capture.error.region_too_large")
        case .regionCompositionFailed:
            return captureLocalizedString("capture.error.region_composition_failed")
        }
    }
}

@MainActor
public final class CaptureService {
    private static let sourceCacheDuration: TimeInterval = 5

    private enum SourceReference {
        case display(SCDisplay)
        case window(SCWindow)
    }

    private let paths: MupawPaths
    private var sourceReferences: [String: SourceReference] = [:]
    private var descriptors: [String: CaptureSourceDescriptor] = [:]
    private var runningApplicationsByBundleIdentifier: [String: SCRunningApplication] = [:]
    private var cachedSourceList: SourceListResult?
    private var cachedSourceListAtUptime: TimeInterval?

    public init(paths: MupawPaths) {
        self.paths = paths
    }

    public func listSources(forceRefresh: Bool = false) async throws -> SourceListResult {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
            let cachedSourceList,
            let cachedSourceListAtUptime,
            now - cachedSourceListAtUptime < Self.sourceCacheDuration
        {
            return cachedSourceList
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        var references: [String: SourceReference] = [:]
        var values: [CaptureSourceDescriptor] = []

        for (index, display) in content.displays.enumerated() {
            let identifier = "display:\(display.displayID)"
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = max(1, Double(filter.pointPixelScale))
            let frame = captureRect(display.frame)
            let descriptor = CaptureSourceDescriptor(
                id: identifier,
                kind: .display,
                title: captureLocalizedFormat("source.display.format", index + 1),
                applicationName: nil,
                pixelWidth: max(1, Int((frame.width * scale).rounded(.up))),
                pixelHeight: max(1, Int((frame.height * scale).rounded(.up))),
                framePoints: frame,
                pointPixelScale: scale,
                isOnScreen: true,
                isPrimaryDisplay: display.displayID == CGMainDisplayID()
            )
            references[identifier] = .display(display)
            values.append(descriptor)
        }

        let windows = content.windows
            .filter { $0.isOnScreen && $0.frame.width >= 80 && $0.frame.height >= 60 }
            .sorted {
                if $0.isActive != $1.isActive {
                    return $0.isActive
                }
                let left = $0.owningApplication?.applicationName ?? ""
                let right = $1.owningApplication?.applicationName ?? ""
                if left == right {
                    return ($0.title ?? "") < ($1.title ?? "")
                }
                return left < right
            }

        for window in windows {
            let identifier = "window:\(window.windowID)"
            let app = window.owningApplication
            let appName = app?.applicationName
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle =
                title?.isEmpty == false
                ? title!
                : (appName ?? captureLocalizedString("source.untitled_window"))
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = max(1, Double(filter.pointPixelScale))
            let frame = captureRect(window.frame)
            let descriptor = CaptureSourceDescriptor(
                id: identifier,
                kind: .window,
                title: displayTitle,
                applicationName: appName,
                applicationBundleIdentifier: app?.bundleIdentifier,
                applicationProcessID: app?.processID,
                pixelWidth: max(1, Int((filter.contentRect.width * scale).rounded(.up))),
                pixelHeight: max(1, Int((filter.contentRect.height * scale).rounded(.up))),
                framePoints: frame,
                pointPixelScale: scale,
                isOnScreen: window.isOnScreen,
                isActive: window.isActive
            )
            references[identifier] = .window(window)
            values.append(descriptor)
        }

        sourceReferences = references
        descriptors = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        var applicationsByBundleIdentifier: [String: SCRunningApplication] = [:]
        for application in content.applications {
            applicationsByBundleIdentifier[application.bundleIdentifier] = application
        }
        runningApplicationsByBundleIdentifier = applicationsByBundleIdentifier
        let result = SourceListResult(refreshedAt: Date(), sources: values)
        cachedSourceList = result
        cachedSourceListAtUptime = now
        return result
    }

    public func capture(_ request: ScreenshotRequest) async throws -> ScreenshotArtifact {
        switch request.mode {
        case .fullScreen:
            let (display, descriptor) = try await resolveDisplay(request.sourceID, mode: request.mode)
            let filter = displayFilter(display, excludingMupawUI: request.excludeMupawUI)
            return try await captureSingleSource(
                request: request,
                filter: filter,
                descriptor: descriptor
            )

        case .window:
            let (window, descriptor) = try await resolveWindow(request.sourceID, mode: request.mode)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return try await captureSingleSource(
                request: request,
                filter: filter,
                descriptor: descriptor
            )

        case .region:
            return try await captureRegion(request)
        }
    }

    private func resolveDisplay(
        _ sourceID: String?,
        mode: ScreenshotCaptureMode
    ) async throws -> (SCDisplay, CaptureSourceDescriptor) {
        let (reference, descriptor) = try await resolveSource(sourceID, mode: mode)
        guard case .display(let display) = reference, descriptor.kind == .display else {
            throw CaptureServiceError.sourceKindMismatch(descriptor.id, mode)
        }
        guard display.width > 0, display.height > 0 else {
            throw CaptureServiceError.invalidSourceSize(descriptor.id)
        }
        return (display, descriptor)
    }

    private func resolveWindow(
        _ sourceID: String?,
        mode: ScreenshotCaptureMode
    ) async throws -> (SCWindow, CaptureSourceDescriptor) {
        let (reference, descriptor) = try await resolveSource(sourceID, mode: mode)
        guard case .window(let window) = reference, descriptor.kind == .window else {
            throw CaptureServiceError.sourceKindMismatch(descriptor.id, mode)
        }
        guard window.frame.width > 0, window.frame.height > 0 else {
            throw CaptureServiceError.invalidSourceSize(descriptor.id)
        }
        return (window, descriptor)
    }

    private func resolveSource(
        _ sourceID: String?,
        mode: ScreenshotCaptureMode
    ) async throws -> (SourceReference, CaptureSourceDescriptor) {
        guard let sourceID, !sourceID.isEmpty else {
            throw CaptureServiceError.sourceRequired(mode)
        }
        if sourceReferences[sourceID] == nil {
            _ = try await listSources(forceRefresh: true)
        }
        guard let reference = sourceReferences[sourceID],
            let descriptor = descriptors[sourceID]
        else {
            throw CaptureServiceError.sourceNotFound(sourceID)
        }
        return (reference, descriptor)
    }

    private func captureSingleSource(
        request: ScreenshotRequest,
        filter: SCContentFilter,
        descriptor: CaptureSourceDescriptor
    ) async throws -> ScreenshotArtifact {
        let scale = max(CGFloat(1), CGFloat(filter.pointPixelScale))
        guard filter.contentRect.width > 0, filter.contentRect.height > 0 else {
            throw CaptureServiceError.invalidSourceSize(descriptor.id)
        }
        let pixelWidth = max(1, Int((filter.contentRect.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((filter.contentRect.height * scale).rounded(.up)))
        try validatePixelDimensions(width: pixelWidth, height: pixelHeight)

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.captureResolution = .best
        configuration.showsCursor = request.includeCursor

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return try writeArtifact(
            image: image,
            source: capturedDescriptor(from: descriptor, image: image),
            request: request
        )
    }

    private func captureRegion(_ request: ScreenshotRequest) async throws -> ScreenshotArtifact {
        guard let region = request.region else {
            throw CaptureServiceError.regionRequired
        }
        if sourceReferences.isEmpty {
            _ = try await listSources(forceRefresh: true)
        }

        let displayGeometries: [CaptureDisplayGeometry] = sourceReferences.compactMap { entry in
            let (identifier, reference) = entry
            guard case .display = reference,
                let descriptor = descriptors[identifier],
                let frame = descriptor.framePoints,
                let scale = descriptor.pointPixelScale
            else {
                return nil
            }
            return CaptureDisplayGeometry(
                sourceID: identifier,
                framePoints: frame,
                pointPixelScale: scale
            )
        }

        let plan: RegionCapturePlan
        do {
            plan = try RegionCapturePlanner.makePlan(
                region: region,
                displays: displayGeometries
            )
        } catch let error as RegionCapturePlanningError {
            switch error {
            case .unsupportedCoordinateSpace, .invalidRegion, .invalidDisplayGeometry:
                throw CaptureServiceError.invalidRegion
            case .noDisplayIntersection:
                throw CaptureServiceError.regionOutsideDisplays
            case .outputTooLarge:
                throw CaptureServiceError.regionTooLarge
            }
        }

        guard
            let context = CGContext(
                data: nil,
                width: plan.outputPixelWidth,
                height: plan.outputPixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw CaptureServiceError.regionCompositionFailed
        }
        context.clear(
            CGRect(
                x: 0,
                y: 0,
                width: plan.outputPixelWidth,
                height: plan.outputPixelHeight
            )
        )
        context.interpolationQuality = .high

        for slice in plan.slices {
            guard case .display(let display)? = sourceReferences[slice.sourceID] else {
                _ = try await listSources(forceRefresh: true)
                guard case .display(let refreshedDisplay)? = sourceReferences[slice.sourceID] else {
                    throw CaptureServiceError.sourceNotFound(slice.sourceID)
                }
                try await drawRegionSlice(
                    slice,
                    display: refreshedDisplay,
                    request: request,
                    plan: plan,
                    context: context
                )
                continue
            }
            try await drawRegionSlice(
                slice,
                display: display,
                request: request,
                plan: plan,
                context: context
            )
        }

        guard let image = context.makeImage() else {
            throw CaptureServiceError.regionCompositionFailed
        }
        let source = CaptureSourceDescriptor(
            id: "region:\(UUID().uuidString.lowercased())",
            kind: .region,
            title: captureLocalizedString("source.region"),
            applicationName: nil,
            pixelWidth: image.width,
            pixelHeight: image.height,
            framePoints: plan.region.rect,
            pointPixelScale: plan.outputPointPixelScale,
            isOnScreen: true
        )
        return try writeArtifact(image: image, source: source, request: request)
    }

    private func drawRegionSlice(
        _ slice: RegionCaptureSlice,
        display: SCDisplay,
        request: ScreenshotRequest,
        plan: RegionCapturePlan,
        context: CGContext
    ) async throws {
        let filter = displayFilter(display, excludingMupawUI: request.excludeMupawUI)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = cgRect(slice.sourceRectPoints)
        configuration.width = slice.destinationPixelRect.width
        configuration.height = slice.destinationPixelRect.height
        configuration.captureResolution = .best
        configuration.showsCursor = request.includeCursor

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let destination = slice.destinationPixelRect
        let drawRect = CGRect(
            x: destination.x,
            y: plan.outputPixelHeight - destination.y - destination.height,
            width: destination.width,
            height: destination.height
        )
        context.draw(image, in: drawRect)
    }

    private func displayFilter(
        _ display: SCDisplay,
        excludingMupawUI: Bool
    ) -> SCContentFilter {
        if excludingMupawUI,
            let application = runningApplicationsByBundleIdentifier[MupawConstants.appBundleIdentifier]
        {
            return SCContentFilter(
                display: display,
                excludingApplications: [application],
                exceptingWindows: []
            )
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private func validatePixelDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0,
            width <= MupawConstants.maximumScreenshotPixelCount / height
        else {
            throw CaptureServiceError.regionTooLarge
        }
    }

    private func capturedDescriptor(
        from descriptor: CaptureSourceDescriptor,
        image: CGImage
    ) -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            id: descriptor.id,
            kind: descriptor.kind,
            title: descriptor.title,
            applicationName: descriptor.applicationName,
            applicationBundleIdentifier: descriptor.applicationBundleIdentifier,
            applicationProcessID: descriptor.applicationProcessID,
            pixelWidth: image.width,
            pixelHeight: image.height,
            framePoints: descriptor.framePoints,
            pointPixelScale: descriptor.pointPixelScale,
            isOnScreen: descriptor.isOnScreen,
            isActive: descriptor.isActive,
            isPrimaryDisplay: descriptor.isPrimaryDisplay
        )
    }

    private func writeArtifact(
        image: CGImage,
        source: CaptureSourceDescriptor,
        request: ScreenshotRequest
    ) throws -> ScreenshotArtifact {
        try ImageArtifactEncoder.writePNG(
            image: image,
            source: source,
            request: request,
            paths: paths
        )
    }

    private func captureRect(_ rect: CGRect) -> CaptureRect {
        CaptureRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    private func cgRect(_ rect: CaptureRect) -> CGRect {
        let value = rect.standardized
        return CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}
