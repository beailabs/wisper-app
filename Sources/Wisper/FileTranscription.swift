import AVFoundation

/// Transcribe un archivo de audio con el motor configurado. Útil para probar sin micrófono.
enum FileTranscription {
    static func run(url: URL, settings: Settings) async throws -> String {
        if settings.backend == .appleLegacy {
            let status = await Permissions.requestSpeech()
            guard status == .authorized else {
                throw WisperError.recognizerUnavailable("permiso de reconocimiento de voz denegado (\(status.rawValue))")
            }
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let transcriber = TranscriberFactory.make(settings: settings)
        try transcriber.begin(format: format)

        let chunk: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            transcriber.append(buffer)
            // Simula el ritmo del micrófono para que el reconocedor no reciba todo de golpe.
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let raw = try await transcriber.finish()
        return TextCleaner.clean(raw, settings: settings)
    }
}
