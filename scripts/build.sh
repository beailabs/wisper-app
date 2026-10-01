#!/bin/zsh
# Compila Wisper y genera build/Wisper.app. Uso: ./scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

# Elige un SDK compatible con el compilador instalado (el más reciente no siempre lo es).
SWIFT_VER=$(swiftc --version 2>&1 | sed -nE 's/.*swiftlang-([0-9]+\.[0-9]+).*/\1/p' | head -1)
SDK=""
for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk "$(xcrun --show-sdk-path 2>/dev/null)" 2>/dev/null | sort -rV); do
  iface="$candidate/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
  [[ -f "$iface" ]] || continue
  if grep -q "swiftlang-$SWIFT_VER" "$iface"; then SDK="$candidate"; break; fi
done
[[ -z "$SDK" ]] && SDK="$(xcrun --show-sdk-path)"
echo "→ SDK: $SDK"

ARCH=$(uname -m)
APP=build/Wisper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compilando…"
swiftc -O -target "$ARCH-apple-macosx14.0" -sdk "$SDK" -module-name Wisper -swift-version 5 \
  Sources/Wisper/*.swift -o "$APP/Contents/MacOS/Wisper"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Icono…"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swiftc -sdk "$SDK" -target "$ARCH-apple-macosx14.0" scripts/make_icon.swift -o build/make_icon
build/make_icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Firmando…"
# Usa un certificado propio llamado "Wisper Dev" si existe: así los permisos sobreviven a las recompilaciones.
if security find-identity -p codesigning 2>/dev/null | grep -q "Wisper Dev"; then
  IDENTITY="Wisper Dev"
else
  IDENTITY="-"
fi
codesign --force --deep --options runtime --entitlements Resources/Wisper.entitlements --sign "$IDENTITY" "$APP"
echo "   firmado con: $IDENTITY"

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Instalando en /Applications…"
  pkill -x Wisper 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Wisper.app
  cp -R "$APP" /Applications/Wisper.app
  open /Applications/Wisper.app
  echo "✓ Wisper instalado y abierto"
else
  echo "✓ $APP listo"
fi
