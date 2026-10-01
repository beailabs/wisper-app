import Foundation
import Combine
import CoreGraphics

/// Ajustes persistentes de la app en UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Hotkey: Int64, CaseIterable, Identifiable {
        case fn = 63
        case rightCommand = 54
        case rightOption = 61
        case rightControl = 62

        var id: Int64 { rawValue }

        var label: String {
            switch self {
            case .fn: return "fn / 🌐"
            case .rightCommand: return "⌘ derecha"
            case .rightOption: return "⌥ derecha"
            case .rightControl: return "⌃ derecha"
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .fn: return .maskSecondaryFn
            case .rightCommand: return .maskCommand
            case .rightOption: return .maskAlternate
            case .rightControl: return .maskControl
            }
        }
    }

    enum Backend: String, CaseIterable, Identifiable {
        case appleModern
        case appleLegacy

        var id: String { rawValue }

        var label: String {
            switch self {
            case .appleModern: return "Apple (en el dispositivo, macOS 26+)"
            case .appleLegacy: return "Apple clásico (SFSpeechRecognizer)"
            }
        }

        var help: String {
            switch self {
            case .appleModern:
                return "Modelo nuevo de Apple. Funciona sin conexión, gratis y con buena calidad. La primera vez descarga el modelo del idioma."
            case .appleLegacy:
                return "Reconocimiento de voz clásico de macOS. Funciona sin conexión si el idioma lo permite."
            }
        }

        static var available: [Backend] {
            if #available(macOS 26.0, *) {
                return [.appleModern, .appleLegacy]
            }
            return [.appleLegacy]
        }

        static var `default`: Backend {
            if #available(macOS 26.0, *) { return .appleModern }
            return .appleLegacy
        }
    }

    enum InsertMode: String, CaseIterable, Identifiable {
        case paste
        case type
        var id: String { rawValue }
        var label: String {
            switch self {
            case .paste: return "Pegar (⌘V, más rápido)"
            case .type: return "Teclear carácter a carácter"
            }
        }
    }

    struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let languages: [Language] = [
        Language(code: "es-ES", name: "Español (España)"),
        Language(code: "es-MX", name: "Español (México)"),
        Language(code: "es-US", name: "Español (EE. UU.)"),
        Language(code: "ca-ES", name: "Català"),
        Language(code: "en-US", name: "English (US)"),
        Language(code: "en-GB", name: "English (UK)"),
        Language(code: "pt-BR", name: "Português (Brasil)"),
        Language(code: "pt-PT", name: "Português (Portugal)"),
        Language(code: "fr-FR", name: "Français"),
        Language(code: "de-DE", name: "Deutsch"),
        Language(code: "it-IT", name: "Italiano"),
    ]

    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var backend: Backend { didSet { defaults.set(backend.rawValue, forKey: "backend") } }
    /// Código de idioma BCP-47 ("es-ES"). Cadena vacía = idioma del sistema.
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var insertMode: InsertMode { didSet { defaults.set(insertMode.rawValue, forKey: "insertMode") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var trailingSpace: Bool { didSet { defaults.set(trailingSpace, forKey: "trailingSpace") } }
    @Published var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }

    /// Pulsaciones más cortas que esto se consideran accidentales.
    let minimumHold: TimeInterval = 0.25

    private init() {
        hotkey = Hotkey(rawValue: Int64(defaults.integer(forKey: "hotkey"))) ?? .fn
        backend = Backend(rawValue: defaults.string(forKey: "backend") ?? "") ?? Backend.default
        language = defaults.string(forKey: "language") ?? ""
        insertMode = InsertMode(rawValue: defaults.string(forKey: "insertMode") ?? "") ?? .paste
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        trailingSpace = defaults.object(forKey: "trailingSpace") as? Bool ?? true
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? false
        if !Backend.available.contains(backend) { backend = Backend.default }
        // El motor clásico se atasca en dictados largos: en macOS 26+ pasamos una vez al moderno.
        if backend == .appleLegacy, Backend.default == .appleModern, !defaults.bool(forKey: "migratedToModern") {
            backend = .appleModern
        }
        defaults.set(true, forKey: "migratedToModern")
    }

    var locale: Locale {
        language.isEmpty ? Locale.current : Locale(identifier: language)
    }
}
