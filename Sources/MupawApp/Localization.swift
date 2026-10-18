import Foundation
import MupawCore

enum L10n {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static func permissionStatus(_ status: PermissionStatus) -> String {
        switch status {
        case .authorized:
            return string("permission.status.authorized")
        case .denied:
            return string("permission.status.denied")
        case .notDetermined:
            return string("permission.status.not_determined")
        case .restricted:
            return string("permission.status.restricted")
        case .unavailable:
            return string("permission.status.unavailable")
        }
    }
}
