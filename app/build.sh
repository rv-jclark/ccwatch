#!/usr/bin/env bash
#
# Build ccwatch.app — the menu bar item, the overlay, and the serve supervisor.
#
#   ./app/build.sh              build into app/build/ccwatch.app
#   ./app/build.sh --run        build, then launch it
#   ./app/build.sh --selftest   build, then run the app's own checks and exit
#   ./app/build.sh --install    build, then copy it into /Applications
#
# ⚠️ This is the one part of ccwatch that needs a build step, and it is the
# reason the constitution's "no build step" constraint is now scoped to
# bin/ccwatch and web/ rather than the whole repository. Nothing in the CLI may
# come to depend on this app: the terminal and the browser have to keep working
# on a machine that has never run swiftc.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
OUT="$HERE/build"
APP="$OUT/ccwatch.app"
BIN="$APP/Contents/MacOS/ccwatch-menu"

run=0 selftest=0 install=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run)      run=1; shift;;
    --selftest) selftest=1; shift;;
    --install)  install=1; shift;;
    -h|--help)  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2;;
  esac
done

command -v swiftc >/dev/null 2>&1 || {
  printf 'swiftc not found. Install the Command Line Tools:\n  xcode-select --install\n' >&2
  exit 1
}

# ⚠️ The CLI path is recorded into the bundle at build time because a GUI app
# inherits a minimal PATH — roughly /usr/bin:/bin:/usr/sbin:/sbin — so
# ~/.local/bin, where `ccwatch setup` installs by default, is invisible to it.
# Resolved through symlinks so that moving the checkout is caught by a rebuild
# rather than by a menu bar that says "ccwatch not found".
CLI="$ROOT/bin/ccwatch"
[ -x "$CLI" ] || { printf 'no executable ccwatch at %s\n' "$CLI" >&2; exit 1; }
VERSION=$("$CLI" --version 2>/dev/null | awk '{print $2}')
[ -n "$VERSION" ] || { printf '%s did not answer --version\n' "$CLI" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ccwatch</string>
  <key>CFBundleDisplayName</key><string>ccwatch</string>
  <key>CFBundleIdentifier</key><string>dev.ccwatch.menu</string>
  <key>CFBundleExecutable</key><string>ccwatch-menu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- No Dock icon and no menu bar of its own: this lives in the status bar. -->
  <key>LSUIElement</key><true/>
  <!-- The overlay and the dashboard talk to 127.0.0.1 over plain HTTP, which
       App Transport Security blocks by default. Scoped to localhost only. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>127.0.0.1</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSIncludesSubdomains</key><false/>
      </dict>
    </dict>
  </dict>
  <!-- Which checkout this bundle was built from. Read by CLILocator. -->
  <key>CCWatchBuiltFrom</key><string>$CLI</string>
</dict>
</plist>
PLIST

# ⚠️ TMPDIR and the module cache are pinned into the build directory. swiftc
# otherwise puts both under the login /var/folders/…/T, which a sandbox may
# refuse — measured here: the compile did not fail, it ground for 15 minutes
# retrying. Pinning them makes a refused build fail fast and in a place you can
# see.
export TMPDIR="$OUT/tmp"
mkdir -p "$TMPDIR"

printf 'compiling (first build fetches the AppKit/WebKit modules, ~1-2 min)\n'
swiftc -O -swift-version 5 \
  -module-cache-path "$OUT/modcache" \
  -framework AppKit -framework WebKit -framework ServiceManagement \
  -o "$BIN" "$HERE/Sources/main.swift" || {
    printf '\nbuild failed\n' >&2; exit 1; }

# Ad-hoc signature. Enough for the app to keep a stable identity on this
# machine — which is what SMAppService needs to register a login item — and not
# enough for someone else to open it without a right-click. Notarising is the
# upgrade, and it needs an Apple Developer account.
codesign --force --sign - --identifier dev.ccwatch.menu "$APP" 2>/dev/null \
  || printf 'note: could not ad-hoc sign; the login item may not stick\n' >&2

printf 'built %s (ccwatch %s)\n' "$APP" "$VERSION"

if [ "$selftest" -eq 1 ]; then
  printf '\n'
  "$BIN" --selftest
  exit $?
fi

if [ "$install" -eq 1 ]; then
  rm -rf /Applications/ccwatch.app \
    && cp -R "$APP" /Applications/ \
    && printf 'installed /Applications/ccwatch.app\n' \
    || { printf 'could not copy into /Applications\n' >&2; exit 1; }
  [ "$run" -eq 1 ] && open /Applications/ccwatch.app
  exit 0
fi

[ "$run" -eq 1 ] && open "$APP"
exit 0
