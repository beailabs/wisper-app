import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: DictationController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Tecla de dictado") {
                Picker("Mantén pulsada", selection: $settings.hotkey) {
                    ForEach(Settings.Hotkey.allCases) { Text($0.label).tag($0) }
                }
                Text("Mantén la tecla pulsada mientras hablas y suéltala para que el texto aparezca donde tengas el cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.hotkey == .fn, let warning = Permissions.fnKeyWarning() {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Button("Abrir ajustes de teclado…") { Permissions.openKeyboardSettings() }
                }
            }

            Section("Reconocimiento de voz") {
                Picker("Motor", selection: $settings.backend) {
                    ForEach(Settings.Backend.available) { Text($0.label).tag($0) }
                }
                Text(settings.backend.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Idioma", selection: $settings.language) {
                    Text("Idioma del sistema").tag("")
                    ForEach(Settings.languages) { Text($0.name).tag($0.code) }
                }
                if settings.backend == .whisperAPI {
                    TextField("Endpoint", text: $settings.apiEndpoint)
                    TextField("Modelo", text: $settings.apiModel)
                    SecureField("API key", text: $settings.apiKey)
                    Text("OpenAI: whisper-1 · Groq: https://api.groq.com/openai/v1/audio/transcriptions con whisper-large-v3-turbo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Escritura") {
                Picker("Insertar texto", selection: $settings.insertMode) {
                    ForEach(Settings.InsertMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Añadir un espacio al final", isOn: $settings.trailingSpace)
                Toggle("Quitar muletillas (eh, em, mmm…)", isOn: $settings.removeFillers)
                Toggle("Sonidos al empezar y terminar", isOn: $settings.playSounds)
            }

            Section("Sistema") {
                Toggle("Abrir Wisper al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                permissionRow("Micrófono", granted: Permissions.microphoneGranted) { Permissions.openMicrophoneSettings() }
                permissionRow("Accesibilidad (tecla y escritura)", granted: controller.hotkeyActive) {
                    Permissions.accessibilityTrusted(prompt: true)
                    Permissions.openAccessibilitySettings()
                }
                if settings.backend == .appleLegacy {
                    permissionRow("Reconocimiento de voz", granted: Permissions.speechGranted) {
                        Task { _ = await Permissions.requestSpeech(); refresh += 1 }
                    }
                }
            }
            .id(refresh)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted {
                Button("Conceder…", action: action)
            }
        }
    }
}
