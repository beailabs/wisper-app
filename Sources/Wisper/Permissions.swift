import AppKit
import AVFoundation
import Speech
import ApplicationServices

enum Permissions {
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    static var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Accesibilidad: necesaria para escuchar la tecla y para pegar/teclear en otras apps.
    @discardableResult
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: Tecla fn / 🌐 del sistema

    /// Valor de "Pulsar la tecla 🌐 para" en Ajustes › Teclado.
    /// 0 = no hacer nada, 1 = cambiar fuente de entrada, 2 = emojis, 3 = dictado de Apple.
    static func fnKeyUsage() -> Int? {
        guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                                    "com.apple.HIToolbox" as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func fnKeyWarning() -> String? {
        switch fnKeyUsage() {
        case 0:
            return nil
        case 1:
            return "La tecla 🌐/fn está configurada para cambiar el idioma del teclado. Ponla en «No hacer nada» para que no interfiera."
        case 2:
            return "La tecla 🌐/fn abre el selector de emojis al soltarla. Ponla en «No hacer nada» en Ajustes › Teclado."
        case 3:
            return "La tecla 🌐/fn activa el dictado de Apple. Ponla en «No hacer nada» para evitar que se solapen."
        default:
            return "Comprueba que en Ajustes › Teclado la opción «Pulsar la tecla 🌐 para» esté en «No hacer nada»."
        }
    }
}
