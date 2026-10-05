import Foundation

enum UpdateInstaller {
    static func script(currentPID: Int32, dmg: URL, target: URL, releaseTag: String, stateRoot: URL) -> String {
        """
        #!/bin/zsh
        set -euo pipefail
        PID=\(currentPID)
        DMG=\(quote(dmg.path))
        TARGET=\(quote(target.path))
        RELEASE_TAG=\(quote(releaseTag))
        STATE=\(quote(stateRoot.path))
        MOUNT=""
        STAGE=""
        SWAPPED=0
        COMMITTED=0
        MESSAGE="Não foi possível preparar a atualização; a versão anterior foi mantida."
        /bin/mkdir -p "$STATE"

        cleanup() {
          local code=$?
          trap - EXIT
          if [[ "$SWAPPED" == 1 && "$COMMITTED" == 0 ]]; then
            /bin/rm -rf "$TARGET"
            if /bin/mv "$STAGE/Previous.app" "$TARGET"; then
              MESSAGE="A instalação falhou; a versão anterior foi restaurada."
              /usr/bin/open -n "$TARGET" 2>/dev/null || true
            else
              MESSAGE="A restauração falhou. A versão anterior está em $STAGE/Previous.app."
              STAGE=""
            fi
          fi
          local result="$STATE/result.plist"
          /bin/rm -f "$result"
          /usr/bin/plutil -create xml1 "$result"
          /usr/bin/plutil -insert releaseTag -string "$RELEASE_TAG" "$result"
          /usr/bin/plutil -insert code -integer "$code" "$result"
          /usr/bin/plutil -insert message -string "$MESSAGE" "$result"
          /bin/cp "$result" "$STATE/../latest-result.plist"
          [[ -z "$MOUNT" ]] || /usr/bin/hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
          [[ -z "$MOUNT" ]] || /bin/rm -rf "$MOUNT"
          [[ -z "$STAGE" ]] || /bin/rm -rf "$STAGE"
          /bin/rm -f "$DMG" "$0"
          exit "$code"
        }
        trap cleanup EXIT

        [[ "$TARGET" == *.app && -d "$TARGET" ]] || { MESSAGE="O app instalado não foi encontrado."; exit 20; }
        MOUNT="$(/usr/bin/mktemp -d /tmp/BottleForgeUpdate.XXXXXX)"
        /usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
        SOURCE="$MOUNT/BottleForge.app"
        [[ -d "$SOURCE" ]] || { MESSAGE="BottleForge.app ausente no DMG."; exit 20; }
        /usr/bin/codesign --verify --deep --strict "$SOURCE"
        IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
        SOURCE_TAG="$(/usr/libexec/PlistBuddy -c 'Print :BottleForgeReleaseTag' "$SOURCE/Contents/Info.plist")"
        [[ "$IDENTIFIER" == app.bottleforge.BottleForge ]] || { MESSAGE="O DMG contém um app de outra identidade."; exit 23; }
        [[ "$SOURCE_TAG" == "$RELEASE_TAG" ]] || { MESSAGE="A versão do app no DMG não corresponde à release."; exit 24; }

        PARENT="$(/usr/bin/dirname "$TARGET")"
        SOURCE_KB="$(/usr/bin/du -sk "$SOURCE" | /usr/bin/awk '{print $1}')"
        AVAILABLE_KB="$(/bin/df -Pk "$PARENT" | /usr/bin/awk 'NR==2 {print $4}')"
        REQUIRED_KB=$((SOURCE_KB + 524288))
        (( AVAILABLE_KB >= REQUIRED_KB )) || { MESSAGE="Espaço insuficiente para preparar a atualização mantendo o app anterior."; exit 22; }
        STAGE="$(/usr/bin/mktemp -d "$PARENT/.BottleForgeUpdate.XXXXXX")"
        /usr/bin/ditto "$SOURCE" "$STAGE/BottleForge.app"
        /usr/bin/codesign --verify --deep --strict "$STAGE/BottleForge.app"

        # Only request app termination after the replacement is completely staged and verified.
        /usr/bin/touch "$STATE/ready"
        for _ in {1..240}; do
          /bin/kill -0 "$PID" 2>/dev/null || break
          /bin/sleep 0.25
        done
        if /bin/kill -0 "$PID" 2>/dev/null; then
          MESSAGE="O BottleForge não encerrou; a atualização foi cancelada mantendo o app anterior."
          exit 25
        fi

        /bin/mv "$TARGET" "$STAGE/Previous.app"
        SWAPPED=1
        /bin/mv "$STAGE/BottleForge.app" "$TARGET"
        /usr/bin/codesign --verify --deep --strict "$TARGET"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        /usr/bin/open -n "$TARGET"
        COMMITTED=1
        MESSAGE="Atualizado para $RELEASE_TAG."
        """
    }
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
