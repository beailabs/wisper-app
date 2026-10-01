import AVFoundation

enum WisperError: LocalizedError {
    case noInputDevice
    case recognizerUnavailable(String)
    case notStarted
    case api(Int, String)
    case missingAPIKey
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No se detecta ningún micrófono."
        case .recognizerUnavailable(let why): return "Reconocedor no disponible: \(why)"
        case .notStarted: return "La sesión de dictado no se había iniciado."
        case .api(let status, let body): return "Error de la API (\(status)): \(body)"
        case .missingAPIKey: return "Falta la API key. Añádela en Ajustes."
        case .invalidEndpoint: return "El endpoint de la API no es una URL válida."
        }
    }
}

/// Captura del micrófono con AVAudioEngine. Entrega buffers y un nivel 0…1 para la UI.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private(set) var format: AVAudioFormat?

    /// Se llama en el hilo de audio.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Se llama en el hilo de audio.
    var onLevel: ((Float) -> Void)?

    /// Crea el motor y devuelve el formato del micrófono sin empezar a grabar todavía.
    func prepare() throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw WisperError.noInputDevice }
        self.engine = engine
        self.format = format
        return format
    }

    func start() throws {
        guard let engine, let format else { throw WisperError.notStarted }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.level(of: buffer))
            self.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Nivel RMS normalizado a 0…1 (rango útil -50 dB … 0 dB).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 50))
    }
}

/// Conversión de buffers entre formatos (frecuencia de muestreo, canales, tipo de muestra).
enum AudioConvert {
    /// Copia un buffer: los del tap del micrófono los reutiliza el motor de audio.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let from = s.mData, let to = d.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }

    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
