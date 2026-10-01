import Foundation
import CoreGraphics
import ApplicationServices

/// Detecta pulsar/soltar una tecla modificadora (fn, ⌘, ⌥, ⌃) en todo el sistema
/// mediante un event tap global. Requiere Accesibilidad.
final class HotkeyMonitor {
    var keyCode: Int64 = Settings.Hotkey.fn.rawValue
    var flag: CGEventFlags = .maskSecondaryFn
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Se pulsó otra tecla mientras se mantenía la tecla de dictado (p. ej. fn+flecha): no es un dictado.
    var onChord: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// true si el tap se creó con permiso de Accesibilidad. Sin él, macOS solo entrega
    /// los eventos dirigidos a Wisper (p. ej. cuando su menú está abierto) y fn no funciona en otras apps.
    private(set) var createdTrusted = false

    var isActive: Bool { tap != nil && CGEvent.tapIsEnabled(tap: tap!) }

    /// Devuelve true si el tap está activo. Es idempotente.
    @discardableResult
    func start() -> Bool {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        // Tap activo (no «solo escucha»): con Accesibilidad recibe los eventos de todas las apps
        // sin necesitar además Monitorización de entrada. Devolvemos el evento intacto.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let trusted = AXIsProcessTrusted()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: userInfo)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: callback, userInfo: userInfo)
        else {
            return false
        }
        createdTrusted = trusted

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    /// Marca la tecla como suelta (cuando el sistema se ha tragado el evento de soltar).
    func markReleased() { isDown = false }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown {
            if isDown { DispatchQueue.main.async { [self] in onChord?() } }
            return
        }
        guard type == .flagsChanged else { return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else {
            // Otro modificador pulsado a la vez (p. ej. fn+⌃): también es un atajo, no un dictado.
            if isDown { DispatchQueue.main.async { [self] in onChord?() } }
            return
        }

        let down = event.flags.contains(flag)
        guard down != isDown else { return }
        isDown = down
        DispatchQueue.main.async { [self] in
            down ? onPress?() : onRelease?()
        }
    }
}
