import AppKit
import Carbon.HIToolbox

/// Escribe texto en la app que tiene el foco: pegando con ⌘V o tecleando carácter a carácter.
enum TextInjector {
    /// Devuelve false si no se pudo escribir (sin Accesibilidad macOS descarta las pulsaciones simuladas);
    /// en ese caso el texto se queda en el portapapeles para pegarlo a mano.
    @MainActor
    @discardableResult
    static func insert(_ text: String, mode: Settings.InsertMode, into target: NSRunningApplication?) async -> Bool {
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return false
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        switch mode {
        case .paste: await paste(text)
        case .type: typeText(text)
        }
        return true
    }

    private static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        try? await Task.sleep(nanoseconds: 60_000_000)
        postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Restaura el portapapeles solo si nadie lo ha tocado mientras tanto.
        if pasteboard.changeCount == ourChangeCount {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    any = true
                }
            }
            return any ? copy : nil
        }
    }

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
    }

    private static func typeText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let chars = Array(text.utf16)
        var index = 0
        while index < chars.count {
            let chunk = Array(chars[index..<min(index + 20, chars.count)])
            index += chunk.count
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            chunk.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: ptr.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: ptr.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }
}

/// Limpieza del texto transcrito.
enum TextCleaner {
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(e+h+m*|e+m+|m+h*m+|u+h+|u+m+|h+m+)(?![\p{L}\p{N}])[,.]?\s*"#
    )

    static func clean(_ raw: String, settings: Settings) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.removeFillers {
            let range = NSRange(text.startIndex..., in: text)
            text = fillerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty { return "" }
        if settings.trailingSpace { text += " " }
        return text
    }
}

enum Sounds {
    enum Kind { case start, stop, error }
    static func play(_ kind: Kind) {
        guard Settings.shared.playSounds else { return }
        let name: String
        switch kind {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .error: name = "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
