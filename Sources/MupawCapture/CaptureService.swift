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
    case sourceNotFound(String)
    case invalidSourceSize(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let identifier):
            return captureLocalizedFormat("capture.error.source_not_found.format", identifier)
        case .invalidSourceSize(let identifier):
            return captureLocalizedFormat("capture.error.invalid_source_size.format", identifier)
        }
    }
}

@MainActor
public final class CaptureService {
    private enum SourceReference {
        case display(SCDisplay)
        case window(SCWindow)
    }

    private let paths: MupawPaths
    private var sourceReferences: [String: SourceReference] = [:]
    private var descriptors: [String: CaptureSourceDescriptor] = [:]

    public init(paths: MupawPaths) {
        self.paths = paths
    }

    public func listSources() async throws -> SourceListResult {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        var references: [String: SourceReference] = [:]
        var values: [CaptureSourceDescriptor] = []

        for (index, display) in content.displays.enumerated() {
            let identifier = "display:\(display.displayID)"
            let descriptor = CaptureSourceDescriptor(
                id: identifier,
                kind: .display,
                title: captureLocalizedFormat("source.display.format", index + 1),
                applicationName: nil,
                pixelWidth: display.width,
                pixelHeight: display.height,
                isOnScreen: true
            )
            references[identifier] = .display(display)
            values.append(descriptor)
        }

        let windows = content.windows
            .filter { $0.isOnScreen && $0.frame.width >= 80 && $0.frame.height >= 60 }
            .sorted {
                let left = $0.owningApplication?.applicationName ?? ""
                let right = $1.owningApplication?.applicationName ?? ""
                if left == right {
                    return ($0.title ?? "") < ($1.title ?? "")
                }
                return left < right
            }

        for window in windows {
            let identifier = "window:\(window.windowID)"
            let appName = window.owningApplication?.applicationName
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle =
                title?.isEmpty == false
                ? title!
                : (appName ?? captureLocalizedString("source.untitled_window"))
            let descriptor = CaptureSourceDescriptor(
                id: identifier,
                kind: .window,
                title: displayTitle,
                applicationName: appName,
                pixelWidth: max(1, Int(window.frame.width.rounded())),
                pixelHeight: max(1, Int(window.frame.height.rounded())),
                isOnScreen: window.isOnScreen
            )
            references[identifier] = .window(window)
            values.append(descriptor)
        }

        sourceReferences = references
        descriptors = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return SourceListResult(refreshedAt: Date(), sources: values)
    }

    public func capture(_ request: ScreenshotRequest) async throws -> ScreenshotArtifact {
        if sourceReferences[request.sourceID] == nil {
            _ = try await listSources()
        }
        guard let source = sourceReferences[request.sourceID],
            let descriptor = descriptors[request.sourceID]
        else {
            throw CaptureServiceError.sourceNotFound(request.sourceID)
        }

        let filter: SCContentFilter
        switch source {
        case .display(let display):
            guard display.width > 0, display.height > 0 else {
                throw CaptureServiceError.invalidSourceSize(request.sourceID)
            }
            filter = SCContentFilter(display: display, excludingWindows: [])

        case .window(let window):
            guard window.frame.width > 0, window.frame.height > 0 else {
                throw CaptureServiceError.invalidSourceSize(request.sourceID)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let scale = max(CGFloat(1), CGFloat(filter.pointPixelScale))
        let pixelWidth = max(1, Int((filter.contentRect.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((filter.contentRect.height * scale).rounded(.up)))

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.captureResolution = .best
        configuration.showsCursor = request.includeCursor

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let capturedSource = CaptureSourceDescriptor(
            id: descriptor.id,
            kind: descriptor.kind,
            title: descriptor.title,
            applicationName: descriptor.applicationName,
            pixelWidth: image.width,
            pixelHeight: image.height,
            isOnScreen: descriptor.isOnScreen
        )
        return try ImageArtifactEncoder.writePNG(
            image: image,
            source: capturedSource,
            request: request,
            paths: paths
        )
    }
}
