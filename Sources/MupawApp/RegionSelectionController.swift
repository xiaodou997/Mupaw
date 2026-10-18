import AppKit
import MupawCore

enum RegionSelectionError: Error, LocalizedError, Equatable {
    case alreadyInProgress
    case cancelled
    case screenConfigurationChanged
    case noScreens

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return L10n.string("capture.error.selection_in_progress")
        case .cancelled:
            return L10n.string("capture.error.selection_cancelled")
        case .screenConfigurationChanged:
            return L10n.string("capture.error.screen_configuration_changed")
        case .noScreens:
            return L10n.string("capture.error.no_screens")
        }
    }
}

@MainActor
final class RegionSelectionController {
    private var activeSession: RegionSelectionSession?

    var isSelecting: Bool {
        activeSession != nil
    }

    func selectRegion() async throws -> CaptureRegion {
        guard activeSession == nil else {
            throw RegionSelectionError.alreadyInProgress
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = RegionSelectionSession { [weak self] result in
                    self?.activeSession = nil
                    continuation.resume(with: result)
                }
                activeSession = session
                session.start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activeSession?.cancel(with: .cancelled)
            }
        }
    }

    func cancel() {
        activeSession?.cancel(with: .cancelled)
    }
}

@MainActor
private final class RegionSelectionSession {
    typealias Completion = (Result<CaptureRegion, Error>) -> Void

    private let completion: Completion
    private var screenOverlays: [RegionSelectionScreenOverlay] = []
    private var localEventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var anchorPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var primaryScreenMaxY: CGFloat = 0
    private var isFinished = false

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    func start() {
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            finish(.failure(RegionSelectionError.noScreens))
            return
        }

        primaryScreenMaxY = primaryScreen.frame.maxY
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                cancel(with: .cancelled)
                return nil
            }
            if event.type == .rightMouseDown {
                cancel(with: .cancelled)
                return nil
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancel(with: .screenConfigurationChanged)
            }
        }

        screenOverlays = screens.enumerated().map { index, screen in
            RegionSelectionScreenOverlay(
                screen: screen,
                session: self,
                showsInstruction: index == 0
            )
        }

        NSApp.activate(ignoringOtherApps: true)
        for overlay in screenOverlays {
            overlay.showInitialState()
        }

        let mouseLocation = NSEvent.mouseLocation
        let keyOverlay =
            screenOverlays.first(where: { $0.screenFrame.contains(mouseLocation) })
            ?? screenOverlays.first
        keyOverlay?.makeInteractionKey()
    }

    func beginSelection(at point: CGPoint) {
        guard !isFinished else { return }
        anchorPoint = point
        currentPoint = point
        updateOverlayWindows()
    }

    func updateSelection(to point: CGPoint) {
        guard anchorPoint != nil, !isFinished else { return }
        currentPoint = point
        updateOverlayWindows()
    }

    func completeSelection(at point: CGPoint) {
        guard let anchorPoint, !isFinished else { return }
        currentPoint = point
        let appKitRect = rect(from: anchorPoint, to: point)
        guard appKitRect.width >= MupawConstants.minimumRegionPointDimension,
            appKitRect.height >= MupawConstants.minimumRegionPointDimension
        else {
            NSSound.beep()
            self.anchorPoint = nil
            currentPoint = nil
            for overlay in screenOverlays {
                overlay.showInitialState()
            }
            return
        }

        let mapped = GlobalDisplayCoordinateMapper.appKitToGlobalDisplay(
            CaptureRect(
                x: appKitRect.origin.x,
                y: appKitRect.origin.y,
                width: appKitRect.width,
                height: appKitRect.height
            ),
            primaryScreenMaxY: primaryScreenMaxY
        )
        finish(
            .success(
                CaptureRegion(
                    coordinateSpace: .globalDisplayPoints,
                    rect: mapped
                )
            )
        )
    }

    func cancel(with error: RegionSelectionError) {
        guard !isFinished else { return }
        finish(.failure(error))
    }

    private var selectionRect: CGRect? {
        guard let anchorPoint, let currentPoint else { return nil }
        return rect(from: anchorPoint, to: currentPoint)
    }

    private func rect(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    private func updateOverlayWindows() {
        guard let selectionRect else { return }
        for overlay in screenOverlays {
            overlay.update(selection: selectionRect)
        }
    }

    private func finish(_ result: Result<CaptureRegion, Error>) {
        guard !isFinished else { return }
        isFinished = true

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for overlay in screenOverlays {
            overlay.close()
        }
        screenOverlays.removeAll()
        completion(result)
    }
}

@MainActor
private final class RegionSelectionScreenOverlay {
    private static let dimColor = NSColor.black.withAlphaComponent(0.42)
    private static let instructionColor = NSColor.black.withAlphaComponent(0.82)
    private static let borderThickness: CGFloat = 2

    let screenFrame: CGRect

    private let interactionPanel: RegionSelectionPanel
    private let dimPanels: [NSPanel]
    private let borderPanels: [NSPanel]
    private let instructionPanel: NSPanel?

    init(
        screen: NSScreen,
        session: RegionSelectionSession,
        showsInstruction: Bool
    ) {
        screenFrame = screen.frame

        let baseLevel = NSWindow.Level.screenSaver
        let decorationLevel = NSWindow.Level(rawValue: baseLevel.rawValue + 1)
        let interactionLevel = NSWindow.Level(rawValue: baseLevel.rawValue + 2)

        dimPanels = (0..<4).map { _ in
            Self.makeDecorationPanel(
                screen: screen,
                level: baseLevel,
                color: Self.dimColor
            )
        }
        borderPanels = (0..<4).map { _ in
            Self.makeDecorationPanel(
                screen: screen,
                level: decorationLevel,
                color: .controlAccentColor
            )
        }
        instructionPanel =
            showsInstruction
            ? Self.makeInstructionPanel(screen: screen, level: decorationLevel)
            : nil

        interactionPanel = RegionSelectionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        Self.configure(
            interactionPanel,
            level: interactionLevel,
            backgroundColor: .clear,
            ignoresMouseEvents: false
        )
        interactionPanel.setFrame(screen.frame, display: false)
        interactionPanel.acceptsMouseMovedEvents = true
        interactionPanel.contentView = RegionSelectionInteractionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            session: session
        )
    }

    func showInitialState() {
        showFullDim()
        hideBorders()
        instructionPanel?.orderFrontRegardless()
        interactionPanel.orderFrontRegardless()
    }

    func makeInteractionKey() {
        interactionPanel.makeKeyAndOrderFront(nil)
        interactionPanel.makeFirstResponder(interactionPanel.contentView)
    }

    func update(selection: CGRect) {
        instructionPanel?.orderOut(nil)

        let intersection = selection.intersection(screenFrame)
        guard !intersection.isNull,
            intersection.width > 0,
            intersection.height > 0
        else {
            showFullDim()
            hideBorders()
            interactionPanel.orderFrontRegardless()
            return
        }

        let bottom = CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: max(0, intersection.minY - screenFrame.minY)
        )
        let top = CGRect(
            x: screenFrame.minX,
            y: intersection.maxY,
            width: screenFrame.width,
            height: max(0, screenFrame.maxY - intersection.maxY)
        )
        let left = CGRect(
            x: screenFrame.minX,
            y: intersection.minY,
            width: max(0, intersection.minX - screenFrame.minX),
            height: intersection.height
        )
        let right = CGRect(
            x: intersection.maxX,
            y: intersection.minY,
            width: max(0, screenFrame.maxX - intersection.maxX),
            height: intersection.height
        )
        applyFrames([bottom, top, left, right], to: dimPanels)

        let thickness = Self.borderThickness
        let borderFrames = [
            CGRect(
                x: intersection.minX,
                y: intersection.minY,
                width: intersection.width,
                height: min(thickness, intersection.height)
            ),
            CGRect(
                x: intersection.minX,
                y: max(intersection.minY, intersection.maxY - thickness),
                width: intersection.width,
                height: min(thickness, intersection.height)
            ),
            CGRect(
                x: intersection.minX,
                y: intersection.minY,
                width: min(thickness, intersection.width),
                height: intersection.height
            ),
            CGRect(
                x: max(intersection.minX, intersection.maxX - thickness),
                y: intersection.minY,
                width: min(thickness, intersection.width),
                height: intersection.height
            ),
        ]
        applyFrames(borderFrames, to: borderPanels)
        interactionPanel.orderFrontRegardless()
    }

    func close() {
        instructionPanel?.orderOut(nil)
        instructionPanel?.close()
        for window in borderPanels + dimPanels {
            window.orderOut(nil)
            window.close()
        }
        interactionPanel.orderOut(nil)
        interactionPanel.close()
    }

    private func showFullDim() {
        applyFrame(screenFrame, to: dimPanels[0])
        for panel in dimPanels.dropFirst() {
            panel.orderOut(nil)
        }
    }

    private func hideBorders() {
        for panel in borderPanels {
            panel.orderOut(nil)
        }
    }

    private func applyFrames(_ frames: [CGRect], to panels: [NSPanel]) {
        for (frame, panel) in zip(frames, panels) {
            applyFrame(frame, to: panel)
        }
    }

    private func applyFrame(_ frame: CGRect, to panel: NSPanel) {
        guard frame.width >= 0.5, frame.height >= 0.5 else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    private static func makeDecorationPanel(
        screen: NSScreen,
        level: NSWindow.Level,
        color: NSColor
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        configure(
            panel,
            level: level,
            backgroundColor: color,
            ignoresMouseEvents: true
        )
        return panel
    }

    private static func makeInstructionPanel(
        screen: NSScreen,
        level: NSWindow.Level
    ) -> NSPanel {
        let textField = NSTextField(labelWithString: L10n.string("capture.region.instructions"))
        textField.font = .systemFont(ofSize: 16, weight: .semibold)
        textField.textColor = .white
        textField.alignment = .center
        textField.maximumNumberOfLines = 1
        textField.sizeToFit()

        let size = CGSize(
            width: textField.frame.width + 36,
            height: textField.frame.height + 22
        )
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        configure(
            panel,
            level: level,
            backgroundColor: instructionColor,
            ignoresMouseEvents: true
        )
        textField.frame = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 11)
        textField.autoresizingMask = [.width, .height]
        panel.contentView = textField
        panel.setFrame(frame, display: false)
        return panel
    }

    private static func configure(
        _ panel: NSPanel,
        level: NSWindow.Level,
        backgroundColor: NSColor,
        ignoresMouseEvents: Bool
    ) {
        panel.level = level
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.backgroundColor = backgroundColor
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = ignoresMouseEvents
    }
}

@MainActor
private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class RegionSelectionInteractionView: NSView {
    private unowned let session: RegionSelectionSession

    init(frame frameRect: NSRect, session: RegionSelectionSession) {
        self.session = session
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        session.beginSelection(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        session.updateSelection(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        session.completeSelection(at: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        session.cancel(with: .cancelled)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            session.cancel(with: .cancelled)
        } else {
            super.keyDown(with: event)
        }
    }
}
