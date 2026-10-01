import AppKit
import AVFoundation

// Modo de prueba con un archivo de audio: `Wisper --transcribe archivo.wav [--backend appleModern|appleLegacy]`
if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), index + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    if let backendIndex = CommandLine.arguments.firstIndex(of: "--backend"),
       backendIndex + 1 < CommandLine.arguments.count,
       let backend = Settings.Backend(rawValue: CommandLine.arguments[backendIndex + 1]) {
        Settings.shared.backend = backend
    }
    if let langIndex = CommandLine.arguments.firstIndex(of: "--language"), langIndex + 1 < CommandLine.arguments.count {
        Settings.shared.language = CommandLine.arguments[langIndex + 1]
    }
    Task {
        do {
            let text = try await FileTranscription.run(url: url, settings: Settings.shared)
            print(text)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
