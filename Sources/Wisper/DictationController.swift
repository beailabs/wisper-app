import AppKit
import AVFoundation
import Combine

/// Máquina de estados del dictado: reposo → grabando → transcribiendo → escrito.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var history: [String] = []
    @Published private(set) var hotkeyActive = false
    @Published private(set) var lastError: String?

    private let settings = Settings.shared
    private let hotkey = HotkeyMonitor()
    private let hud = HUDPanel()
    private var recorder: AudioRecorder?
    private var transcriber: Transcriber?
    private var targetApp: NSRunningApplication?
    private var pressedAt: Date?
    private var session = 0
    private var retryTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var releaseWatchdog: Timer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onChord = { [weak self] in self?.cancelRecording() }
        applyHotkey()
        settings.$hotkey
            .dropFirst()
            .sink { [weak self] _ in self?.applyHotkey() }
            .store(in: &cancellables)
        warmUp()
        Publishers.Merge(settings.$backend.map { _ in () }, settings.$language.map { _ in () })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.warmUp() }
            .store(in: &cancellables)
    }

    /// Deja el modelo de voz descargado y listo para que el primer dictado empiece al instante.
    private func warmUp() {
        guard settings.backend == .appleModern else { return }
        if #available(macOS 26.0, *) {
            let locale = settings.locale
            Task.detached { _ = try? await ModernAppleTranscriber.warmUp(locale: locale) }
        }
    }

    /// Intenta (re)activar el tap. Si falta el permiso, reintenta cada 2 s hasta conseguirlo.
    func applyHotkey() {
        hotkey.keyCode = settings.hotkey.rawValue
        hotkey.flag = settings.hotkey.flag
        let trusted = AXIsProcessTrusted()
        // Un tap creado sin Accesibilidad sigue limitado aunque luego se conceda: hay que recrearlo.
        if trusted && !hotkey.createdTrusted && state == .idle { hotkey.stop() }
        hotkeyActive = hotkey.start() && trusted
        if hotkeyActive {
            retryTimer?.invalidate()
            retryTimer = nil
        } else if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.applyHotkey() }
            }
        }
    }

    // MARK: Pulsar / soltar

    private func handlePress() {
        guard state == .idle else { return }
        hideTask?.cancel()
        targetApp = NSWorkspace.shared.frontmostApplication

        let recorder = AudioRecorder()
        do {
            let format = try recorder.prepare()
            let transcriber = TranscriberFactory.make(settings: settings)
            try transcriber.begin(format: format)

            recorder.onBuffer = { [weak transcriber] buffer in transcriber?.append(buffer) }
            recorder.onLevel = { [weak self] level in
                DispatchQueue.main.async { self?.hud.model.push(level: level) }
            }
            try recorder.start()

            self.recorder = recorder
            self.transcriber = transcriber
            pressedAt = Date()
            state = .recording
            lastError = nil
            hud.show(.recording)
            Sounds.play(.start)
            startReleaseWatchdog()
        } catch {
            recorder.stop()
            fail(error.localizedDescription)
        }
    }

    private func handleRelease() {
        guard state == .recording, let recorder, let transcriber else { return }
        stopReleaseWatchdog()
        recorder.stop()
        self.recorder = nil

        let held = Date().timeIntervalSince(pressedAt ?? Date())
        if held < settings.minimumHold {
            transcriber.cancel()
            self.transcriber = nil
            state = .idle
            hud.hide()
            return
        }

        state = .transcribing
        hud.show(.transcribing)
        Sounds.play(.stop)

        session += 1
        let current = session
        let target = targetApp
        // Red de seguridad: si el motor no responde, no dejamos la app colgada en «Transcribiendo…».
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, current == self.session, self.state == .transcribing else { return }
            self.session += 1
            transcriber.cancel()
            self.transcriber = nil
            self.fail("La transcripción ha tardado demasiado")
        }
        Task {
            do {
                let raw = try await transcriber.finish()
                guard current == session else { return }
                let text = TextCleaner.clean(raw, settings: settings)
                if text.isEmpty {
                    fail("No se ha entendido nada")
                } else {
                    history.insert(text, at: 0)
                    history = Array(history.prefix(20))
                    let inserted = await TextInjector.insert(text, mode: settings.insertMode, into: target)
                    state = .idle
                    if inserted {
                        hud.show(.done(text))
                        hideLater(after: 1.2)
                    } else {
                        lastError = "Sin permiso de Accesibilidad: el texto está en el portapapeles"
                        hud.show(.failed("Copiado · pulsa ⌘V (falta Accesibilidad)"))
                        Sounds.play(.error)
                        hideLater(after: 3)
                    }
                }
            } catch {
                guard current == session else { return }
                fail(error.localizedDescription)
            }
            if current == session { self.transcriber = nil }
        }
    }

    /// Cancela en silencio si la tecla se usó como parte de un atajo.
    private func cancelRecording() {
        guard state == .recording else { return }
        stopReleaseWatchdog()
        recorder?.stop()
        recorder = nil
        transcriber?.cancel()
        transcriber = nil
        state = .idle
        hud.hide()
    }

    /// En grabaciones largas macOS puede desactivar el event tap y perderse el evento de soltar la tecla.
    /// Comprobamos el estado real del teclado para no quedarnos grabando para siempre.
    private func startReleaseWatchdog() {
        stopReleaseWatchdog()
        var misses = 0
        releaseWatchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                let held = CGEventSource.flagsState(.combinedSessionState).contains(self.settings.hotkey.flag)
                misses = held ? 0 : misses + 1
                if misses >= 2 {
                    self.hotkey.markReleased()
                    self.hotkey.start()
                    self.handleRelease()
                }
            }
        }
    }

    private func stopReleaseWatchdog() {
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
    }

    private func fail(_ message: String) {
        lastError = message
        state = .idle
        hud.show(.failed(message))
        Sounds.play(.error)
        hideLater(after: 2.5)
    }

    private func hideLater(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .idle else { return }
            self.hud.hide()
        }
    }
}
