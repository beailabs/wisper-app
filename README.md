# Wisper

Dictado por voz para macOS al estilo Wispr Flow: **mantén pulsada `fn`, habla y suelta**. El texto aparece donde tengas el cursor, en cualquier app.

## Cómo funciona

1. Mantienes `fn` (o 🌐). Aparece una píldora con la onda de tu voz en la parte inferior de la pantalla.
2. Hablas.
3. Sueltas. Wisper transcribe y pega el texto en la app que estaba activa. Tu portapapeles se restaura después.

- Pulsaciones de menos de 0,25 s se ignoran.
- Si pulsas otra tecla mientras mantienes `fn` (fn+flecha, fn+F1…), no graba nada.
- El icono 🎙 de la barra de menús muestra el estado, el historial de los últimos dictados (clic para copiar) y los ajustes.

## Motores de reconocimiento

| Motor | Dónde corre | Notas |
|---|---|---|
| Apple moderno (`SpeechAnalyzer`) | En tu Mac | Por defecto en macOS 26+. Gratis, sin internet y con puntuación. La primera vez descarga el modelo del idioma. |
| Apple clásico (`SFSpeechRecognizer`) | En tu Mac o en Apple | Para macOS 14–15. Pide permiso de reconocimiento de voz. |

## Compilar e instalar

Solo hacen falta las Command Line Tools de Xcode.

```sh
./scripts/build.sh            # genera build/Wisper.app
./scripts/build.sh --install  # además la copia a /Applications y la abre
```

El script elige automáticamente un SDK compatible con tu versión de Swift.

## Instalar Wisper con Claude Code

¿No sabes instalar una app desde GitHub? Si tienes Claude Code instalado en tu Mac, copia y pega este mensaje para que descargue e instale Wisper:

> Descarga e instala Wisper desde este repositorio de GitHub: https://github.com/beailabs/wisper-app. Hazlo todo por mí y explícame con palabras sencillas cualquier paso que necesite completar, como conceder los permisos de Micrófono y Accesibilidad. Antes de reemplazar una instalación existente, consúltamelo.

Wisper solo funciona en macOS. Al abrirla por primera vez, macOS te pedirá permiso para usar el micrófono y Accesibilidad; este último permite detectar la tecla de dictado y escribir el texto en otras apps.

## Primera vez

1. Cierra Wispr Flow u otra app que use `fn`, o se escribirá el texto dos veces.
2. En Ajustes del Sistema › Teclado, pon **«Pulsar la tecla 🌐 para» → «No hacer nada»**.
3. Abre Wisper y concede **Micrófono** y **Accesibilidad**. La accesibilidad sirve para detectar `fn` y para pegar en otras apps. Wisper detecta el permiso solo, sin reiniciar.
4. Opcional: en Ajustes de Wisper activa «Abrir Wisper al iniciar sesión».

> Al recompilar, la firma de la app cambia y macOS puede pedir de nuevo el permiso de Accesibilidad. Quita Wisper de la lista y vuelve a añadirlo. Si creas un certificado de firma de código llamado `Wisper Dev` en Acceso a Llaveros, el script lo usa y los permisos se conservan.

## Estructura

```
Sources/Wisper/
  main.swift                 Punto de entrada y modo --transcribe
  FileTranscription.swift    Transcribe un archivo de audio (pruebas)
  AppDelegate.swift          Icono y menú de la barra, bienvenida
  DictationController.swift  Máquina de estados: pulsar → grabar → transcribir → escribir
  HotkeyMonitor.swift        Event tap global para fn / ⌘ / ⌥ / ⌃ derecha
  AudioRecorder.swift        Micrófono con AVAudioEngine y nivel para la onda
  Transcriber.swift          Los motores de reconocimiento de Apple
  TextInjector.swift         Pegado con ⌘V o tecleo, limpieza de texto y sonidos
  HUD.swift                  Píldora flotante con la onda de voz
  SettingsView.swift         Ventana de ajustes (SwiftUI)
  Settings.swift             Preferencias y Llavero
  Permissions.swift          Permisos del sistema y aviso de la tecla 🌐
```
