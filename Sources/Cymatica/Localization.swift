import Foundation

/// Interface language, chosen in Settings. Uzbek until the user picks another.
enum Language: String, CaseIterable {
    case uz, ru, en

    /// The language's name in itself, for the picker.
    var nativeName: String {
        switch self {
        case .uz: "O'zbekcha"
        case .ru: "Русский"
        case .en: "English"
        }
    }

    static var current: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .uz
    }
}

/// The string for the current interface language. Translations sit next to each other
/// at the call site, so a missing one shows up in review instead of at runtime.
func tr(_ uz: String, _ ru: String, _ en: String) -> String {
    switch Language.current {
    case .uz: uz
    case .ru: ru
    case .en: en
    }
}
