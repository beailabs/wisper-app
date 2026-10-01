import AVFoundation
import Speech

/// Motor de transcripción. Recibe audio en tiempo real y devuelve el texto al terminar.
protocol Transcriber: AnyObject {
    func begin(format: AVAudioFormat) throws
    /// Se llama desde el hilo de audio.
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

enum TranscriberFactory {
    static func make(settings: Settings) -> Transcriber {
        switch settings.backend {
        case .appleModern:
            if #available(macOS 26.0, *) {
                return ModernAppleTranscriber(locale: settings.locale)
            }
            return LegacyAppleTranscriber(locale: settings.locale)
        case .appleLegacy:
            return LegacyAppleTranscriber(locale: settings.locale)
        case .whisperAPI:
            return WhisperAPITranscriber(
                endpoint: settings.apiEndpoint,
                apiKey: settings.apiKey,
                model: settings.apiModel,
                language: settings.language.isEmpty ? nil : String(settings.language.prefix(2))
            )
        }
    }
}

// MARK: - Apple clásico (SFSpeechRecognizer)

final class LegacyAppleTranscriber: Transcriber, @unchecked Sendable {
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Texto de los tramos ya cerrados. SFSpeechRecognizer corta cada ~1 min, así que encadenamos tramos.
    private var segments: [String] = []
    private var latest = ""
    private var ending = false
    private var generation = 0
    private var outcome: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?

    init(locale: Locale) { self.locale = locale }

    func begin(format: AVAudioFormat) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw WisperError.recognizerUnavailable("idioma \(locale.identifier) no soportado")
        }
        guard recognizer.isAvailable else {
            throw WisperError.recognizerUnavailable("sin conexión o modelo no instalado")
        }
        self.recognizer = recognizer
        lock.lock()
        startSegment()
        lock.unlock()
    }

    /// Abre un tramo nuevo. Llamar con el lock tomado.
    private func startSegment() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        generation += 1
        let gen = generation
        latest = ""
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, generation: gen)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation gen: Int) {
        lock.lock()
        guard gen == generation, outcome == nil else { lock.unlock(); return }
        if let result { latest = result.bestTranscription.formattedString }
        let segmentEnded = (result?.isFinal ?? false) || error != nil
        guard segmentEnded else { lock.unlock(); return }

        if !latest.isEmpty { segments.append(latest) }
        latest = ""
        if ending {
            let text = joined
            lock.unlock()
            complete(text.isEmpty && error != nil ? .failure(error!) : .success(text))
        } else {
            // El reconocedor cerró el tramo por su cuenta (límite de duración): seguimos en uno nuevo.
            startSegment()
            lock.unlock()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func finish() async throws -> String {
        lock.lock()
        ending = true
        let request = self.request
        lock.unlock()
        request?.endAudio()
        // Si el reconocedor tarda en dar el resultado final, devolvemos lo último que tenemos.
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.complete(.success(self.currentText))
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let outcome {
                lock.unlock()
                cont.resume(with: outcome)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        request = nil
        lock.unlock()
        task?.cancel()
        complete(.success(""))
    }

    /// Llamar con el lock tomado.
    private var joined: String {
        (segments + (latest.isEmpty ? [] : [latest])).joined(separator: " ")
    }

    private var currentText: String {
        lock.lock(); defer { lock.unlock() }
        return joined
    }

    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let cont = continuation
        continuation = nil
        let task = self.task
        lock.unlock()
        task?.finish()
        cont?.resume(with: result)
    }
}

// MARK: - Apple moderno (SpeechAnalyzer, macOS 26+)

@available(macOS 26.0, *)
final class ModernAppleTranscriber: Transcriber, @unchecked Sendable {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var work: Task<String, Error>?

    /// Se usa solo desde el hilo de audio (append) y al final (finish), nunca a la vez.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Audio recibido antes de conocer el formato del modelo (solo la primera vez).
    private var pending: [AVAudioPCMBuffer] = []

    init(locale: Locale) { self.locale = locale }

    // MARK: Precarga

    /// Formato del modelo por idioma, ya comprobado e instalado. Evita repetir la comprobación en cada dictado.
    private static let cacheLock = NSLock()
    private static var readyFormats: [String: AVAudioFormat] = [:]

    private static func cachedFormat(for locale: Locale) -> AVAudioFormat? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return readyFormats[locale.identifier]
    }

    /// Descarga el modelo si hace falta y deja el formato en caché. Llamar al arrancar la app.
    static func warmUp(locale: Locale) async throws -> AVAudioFormat {
        if let format = cachedFormat(for: locale) { return format }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try await ensureAssets(for: module, locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw WisperError.recognizerUnavailable("sin formato de audio compatible")
        }
        cacheLock.lock()
        readyFormats[locale.identifier] = format
        cacheLock.unlock()
        return format
    }

    // MARK: Sesión

    func begin(format: AVAudioFormat) throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = inputCont

        // Si el modelo ya está listo, convertimos desde el primer buffer sin esperar a nada.
        if let cached = Self.cachedFormat(for: locale) {
            try configure(from: format, to: cached)
        }

        let locale = self.locale
        work = Task { [weak self] in
            let target = try await Self.warmUp(locale: locale)
            try self?.lockedConfigure(from: format, to: target)

            try await analyzer.prepareToAnalyze(in: target)
            let collector = Task<String, Error> {
                var pieces: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    pieces.append(String(result.text.characters))
                }
                // Cada trozo ya trae sus espacios; unirlos con " " partiría palabras («Quer emos»).
                return pieces.joined()
            }
            try await analyzer.start(inputSequence: inputStream)
            // Espera a que se cierre la entrada (finish) y termina de procesar lo que quede.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        }
    }

    private func lockedConfigure(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        lock.lock(); defer { lock.unlock() }
        guard converter == nil else { return }
        try configure(from: source, to: target)
        // Vacía lo que llegó mientras se preparaba el modelo.
        for buffer in pending { yield(buffer) }
        pending.removeAll()
    }

    private func configure(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw WisperError.recognizerUnavailable("no se puede convertir el audio del micrófono")
        }
        self.converter = converter
        self.target = target
    }

    /// Llamar con el lock tomado.
    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target,
              let converted = AudioConvert.convert(buffer, using: converter, to: target) else { return }
        inputContinuation?.yield(AnalyzerInput(buffer: converted))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if converter != nil {
            yield(buffer)
        } else if let copy = AudioConvert.copy(buffer) {
            pending.append(copy)
        }
    }

    func finish() async throws -> String {
        lock.lock()
        inputContinuation?.finish()
        lock.unlock()
        guard let work else { throw WisperError.notStarted }
        return try await work.value
    }

    func cancel() {
        lock.lock()
        inputContinuation?.finish()
        pending.removeAll()
        lock.unlock()
        work?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }

    /// Descarga el modelo del idioma si aún no está instalado.
    private static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        let match = supported.first {
            $0.identifier(.bcp47).lowercased() == locale.identifier(.bcp47).lowercased()
        } ?? supported.first {
            $0.language.languageCode == locale.language.languageCode
        }
        guard match != nil else {
            throw WisperError.recognizerUnavailable("el idioma \(locale.identifier) no está soportado por SpeechTranscriber")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

// MARK: - API compatible con OpenAI Whisper

final class WhisperAPITranscriber: Transcriber, @unchecked Sendable {
    private let endpoint: String
    private let apiKey: String
    private let model: String
    private let language: String?

    private let queue = DispatchQueue(label: "wisper.api.writer")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var fileURL: URL?

    init(endpoint: String, apiKey: String, model: String, language: String?) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.language = language
    }

    func begin(format: AVAudioFormat) throws {
        guard !apiKey.isEmpty else { throw WisperError.missingAPIKey }
        guard URL(string: endpoint) != nil else { throw WisperError.invalidEndpoint }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisper-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
            throw WisperError.recognizerUnavailable("no se puede convertir el audio a 16 kHz")
        }
        self.file = file
        self.converter = converter
        self.fileURL = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let file, let converter else { return }
            if let out = AudioConvert.convert(buffer, using: converter, to: file.processingFormat) {
                try? file.write(from: out)
            }
        }
    }

    func finish() async throws -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.file = nil // cierra y vuelca el archivo
                cont.resume()
            }
        }
        guard let fileURL, let url = URL(string: endpoint) else { throw WisperError.notStarted }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let audio = try Data(contentsOf: fileURL)
        let boundary = "wisper-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        if let language { field("language", language) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw WisperError.api(status, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["text"] as? String ?? ""
    }

    func cancel() {
        queue.async {
            self.file = nil
            if let url = self.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }
}
