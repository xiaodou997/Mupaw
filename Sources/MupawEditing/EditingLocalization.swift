import Foundation
import MupawCore

enum EditingL10n {
    static func string(_ key: String, fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key, fallback: fallback),
            locale: Locale.current,
            arguments: arguments
        )
    }

    static func historyAction(_ action: ProjectHistoryAction) -> String {
        switch action {
        case .undo:
            return string("editing.history.undo", fallback: "undo")
        case .redo:
            return string("editing.history.redo", fallback: "redo")
        }
    }
}
