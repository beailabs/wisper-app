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
| API Whisper | En la nube | OpenAI (`whisper-1`) o Groq (`whisper-large-v3-turbo`). Necesita API key, que se guarda en el Llavero. |

## Compilar e instalar

Solo hacen falta las Command Line Tools de Xcode.

```sh
./scripts/build.sh            # genera build/Wisper.app
./scripts/build.sh --install  # además la copia a /Applications y la abre
```

El script elige automáticamente un SDK compatible con tu versión de Swift.

## Instalación asistida por un agente

Si estás usando un agente de programación, puedes pedirle que instale Wisper en este Mac. El agente debe comprobar primero que el sistema es macOS y que están disponibles `swiftc`, `xcrun`, `codesign` e `iconutil`. Después puede ejecutar desde la carpeta del proyecto:

```sh
./scripts/build.sh --install
```

Esto compila la app, la copia a `/Applications/Wisper.app` y la abre. El script reemplaza cualquier copia que ya exista en esa ruta; si la hay, el agente debe avisarte antes de sustituirla. La primera vez, concede a Wisper los permisos de Micrófono y Accesibilidad cuando macOS los solicite. Accesibilidad es necesaria para detectar la tecla global y escribir en otras apps.

Si solo quieres compilarla sin instalarla, ejecuta `./scripts/build.sh`; la app quedará en `build/Wisper.app`.

## Primera vez

1. Cierra Wispr Flow u otra app que use `fn`, o se escribirá el texto dos veces.
2. En Ajustes del Sistema › Teclado, pon **«Pulsar la tecla 🌐 para» → «No hacer nada»**.
3. Abre Wisper y concede **Micrófono** y **Accesibilidad**. La accesibilidad sirve para detectar `fn` y para pegar en otras apps. Wisper detecta el permiso solo, sin reiniciar.
4. Opcional: en Ajustes de Wisper activa «Abrir Wisper al iniciar sesión».

> Al recompilar, la firma de la app cambia y macOS puede pedir de nuevo el permiso de Accesibilidad. Quita Wisper de la lista y vuelve a añadirlo. Si creas un certificado de firma de código llamado `Wisper Dev` en Acceso a Llaveros, el script lo usa y los permisos se conservan.

## Probar sin micrófono

```sh
say -v "Eddy (Spanish (Spain))" -o prueba.wav --data-format=LEI16@16000 "Hola, esto es una prueba"
build/Wisper.app/Contents/MacOS/Wisper --transcribe prueba.wav --backend appleModern --language es-ES
```

## Estructura

```
Sources/Wisper/
  main.swift                 Punto de entrada y modo --transcribe
  FileTranscription.swift    Transcribe un archivo de audio (pruebas)
  AppDelegate.swift          Icono y menú de la barra, bienvenida
  DictationController.swift  Máquina de estados: pulsar → grabar → transcribir → escribir
  HotkeyMonitor.swift        Event tap global para fn / ⌘ / ⌥ / ⌃ derecha
  AudioRecorder.swift        Micrófono con AVAudioEngine y nivel para la onda
  Transcriber.swift          Los tres motores de reconocimiento
  TextInjector.swift         Pegado con ⌘V o tecleo, limpieza de texto y sonidos
  HUD.swift                  Píldora flotante con la onda de voz
  SettingsView.swift         Ventana de ajustes (SwiftUI)
  Settings.swift             Preferencias y Llavero
  Permissions.swift          Permisos del sistema y aviso de la tecla 🌐
```
