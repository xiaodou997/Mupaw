import Foundation

public enum FileNameSanitizer {
    public static func sanitizedBaseName(_ proposedName: String?, fallback: String) -> String {
        let source = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmpty = (source?.isEmpty == false) ? source! : fallback
        let withoutExtension = (nonEmpty as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = withoutExtension.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: #"[- ]{2,}"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "- ."))
        return String((collapsed.isEmpty ? fallback : collapsed).prefix(80))
    }

}
