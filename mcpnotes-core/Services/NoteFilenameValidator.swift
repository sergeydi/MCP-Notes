import Foundation

/// Validates a proposed note filename (without the .md extension).
public struct NoteFilenameValidator {
    private static let allowed: CharacterSet = {
        var cs = CharacterSet.letters
        cs.formUnion(.decimalDigits)
        cs.formUnion(CharacterSet(charactersIn: " -_."))
        return cs
    }()

    public static let maxLength = 200

    public enum ValidationResult: Equatable {
        case valid
        case empty
        case tooLong
        case forbiddenCharacter
    }

    public static func validate(_ draft: String) -> ValidationResult {
        let s = draft.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .empty }
        if s.count > maxLength { return .tooLong }
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) { return .forbiddenCharacter }
        return .valid
    }
}
