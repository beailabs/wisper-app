import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        Task { await bootstrap() }
    }

    private func bootstrap() async {
        _ = await Permissions.requestMicrophone()
        if Settings.shared.backend == .appleLegacy {
            _ = await Permissions.requestSpeech()
        }
        let trusted = Permissions.accessibilityTrusted(prompt: true)
        controller.start()

        let firstRun = !UserDefaults.standard.bool(forKey: "didShowWelcome")
        if !trusted || !controller.hotkeyActive || firstRun {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            showWelcome(trusted: trusted)
        }
    }

    // MARK: Icono

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let image: NSImage?
        switch controller.state {
        case .idle:
            image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Wisper")
            image?.isTemplate = true
        case .recording:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Grabando")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
        case .transcribing:
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribiendo")
            image?.isTemplate = true
        }
        button.image = image
    }

    // MARK: Menú

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch controller.state {
        case .idle: status = controller.hotkeyActive ? "Listo · mantén \(Settings.shared.hotkey.label) para dictar" : "⚠️ Falta el permiso de Accesibilidad"
        case .recording: status = "Grabando…"
        case .transcribing: status = "Transcribiendo…"
        }
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if !controller.hotkeyActive {
            menu.addItem(withTitle: "Conceder permiso de Accesibilidad…", action: #selector(openAccessibility), keyEquivalent: "")
        }
        if let error = controller.lastError {
            let item = NSMenuItem(title: "Último error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if controller.history.isEmpty {
            let item = NSMenuItem(title: "Sin dictados todavía", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Historial (clic para copiar)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, text) in controller.history.prefix(8).enumerated() {
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = preview.count > 60 ? String(preview.prefix(60)) + "…" : preview
                let item = NSMenuItem(title: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: "Acerca de Wisper", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir de Wisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard controller.history.indices.contains(sender.tag) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(controller.history[sender.tag], forType: .string)
    }

    @objc private func openAccessibility() {
        Permissions.accessibilityTrusted(prompt: true)
        Permissions.openAccessibilitySettings()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: Settings.shared, controller: controller)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Ajustes de Wisper"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Wisper",
            .applicationVersion: "1.0.0",
            .credits: NSAttributedString(string: "Dictado por voz con la tecla fn. Mantén, habla, suelta."),
        ])
    }

    private func showWelcome(trusted: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Bienvenida a Wisper"
        alert.informativeText = trusted
            ? "Mantén pulsada la tecla \(Settings.shared.hotkey.label), habla y suéltala. El texto aparecerá donde tengas el cursor.\n\nWisper vive en la barra de menús (icono del micrófono)."
            : "Para escuchar la tecla \(Settings.shared.hotkey.label) y escribir en otras apps, Wisper necesita el permiso de Accesibilidad.\n\nActívalo en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad y vuelve aquí. La app lo detectará sola."
        alert.addButton(withTitle: trusted ? "Entendido" : "Abrir Accesibilidad")
        if !trusted { alert.addButton(withTitle: "Más tarde") }
        alert.addButton(withTitle: "Ajustes de Wisper…")
        let response = alert.runModal()
        let settingsButton: NSApplication.ModalResponse = trusted ? .alertSecondButtonReturn : .alertThirdButtonReturn
        if response == settingsButton {
            openSettings()
        } else if !trusted && response == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }
}
