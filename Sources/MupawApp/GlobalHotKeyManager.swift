import Carbon.HIToolbox
import Foundation

enum GlobalCaptureShortcut: UInt32, CaseIterable, Identifiable, Hashable {
    case fullScreen = 1
    case window = 2
    case region = 3

    var id: UInt32 { rawValue }

    var keyCode: UInt32 {
        switch self {
        case .fullScreen:
            return UInt32(kVK_ANSI_1)
        case .window:
            return UInt32(kVK_ANSI_2)
        case .region:
            return UInt32(kVK_ANSI_3)
        }
    }

    var displayText: String {
        switch self {
        case .fullScreen:
            return "⌃⌥⌘1"
        case .window:
            return "⌃⌥⌘2"
        case .region:
            return "⌃⌥⌘3"
        }
    }
}

struct GlobalHotKeyRegistration: Identifiable, Equatable {
    enum State: Equatable {
        case registered
        case conflict
        case failed(OSStatus)
    }

    let shortcut: GlobalCaptureShortcut
    let state: State

    var id: UInt32 { shortcut.id }
}

@MainActor
final class GlobalHotKeyManager {
    typealias Handler = @MainActor (GlobalCaptureShortcut) -> Void

    private static let signature: OSType = 0x4D_55_50_57  // MUPW
    private let handler: Handler
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [GlobalCaptureShortcut: EventHotKeyRef] = [:]

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() -> [GlobalHotKeyRegistration] {
        stop()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installationStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    manager.receive(identifier: identifier)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installationStatus == noErr else {
            return GlobalCaptureShortcut.allCases.map {
                GlobalHotKeyRegistration(shortcut: $0, state: .failed(installationStatus))
            }
        }

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        return GlobalCaptureShortcut.allCases.map { shortcut in
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: Self.signature,
                id: shortcut.rawValue
            )
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeyRefs[shortcut] = reference
                return GlobalHotKeyRegistration(shortcut: shortcut, state: .registered)
            }
            if status == eventHotKeyExistsErr {
                return GlobalHotKeyRegistration(shortcut: shortcut, state: .conflict)
            }
            return GlobalHotKeyRegistration(shortcut: shortcut, state: .failed(status))
        }
    }

    func stop() {
        for reference in hotKeyRefs.values {
            UnregisterEventHotKey(reference)
        }
        hotKeyRefs.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func receive(identifier: EventHotKeyID) {
        guard identifier.signature == Self.signature,
            let shortcut = GlobalCaptureShortcut(rawValue: identifier.id)
        else {
            return
        }
        handler(shortcut)
    }
}
