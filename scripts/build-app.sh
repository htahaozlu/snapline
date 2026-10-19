#!/usr/bin/env bash
# build-app.sh — build, bundle and sign build/Snapline.app (Swift shell + libnokta.a).
#
# Called by `zig build app` (build.zig sets NOKTA_OPTIMIZE and depends on the install step so
# zig-out/ already exists); also works standalone from anywhere:  scripts/build-app.sh
#
# Environment
#   NOKTA_OPTIMIZE       debug | small                      (default: small)
#   NOKTA_UNIVERSAL=1    also build x86_64 and lipo into a universal binary
#   NOKTA_CORE_INSTALLED=1  set by `zig build app`: zig-out/ was just installed in this mode,
#                        reuse it. Otherwise the core is always rebuilt in NOKTA_OPTIMIZE (the
#                        Zig cache makes an unchanged rebuild cheap), so a stale or Debug
#                        libnokta.a can never end up in a release bundle.
#   NOKTA_SWIFT_OPT      override the Swift optimisation flags (e.g. "-O -wmo")
#   NOKTA_EXTRA_LINK     extra swiftc args appended to the link (words; test hook). The linked
#                        binary must still import the real core's AX and event-tap APIs, or the
#                        build stops (check_real_core): a stub or inert core never ships.
#   NOKTA_EXTRA_LINK_X86_64   same, for the x86_64 slice (default: NOKTA_EXTRA_LINK)
#   NOKTA_SIGN_IDENTITY  SHA-1 of the signing identity   (default: dev cert, see below)
#   NOKTA_KEYCHAIN       keychain holding it              (default: ~/Library/Keychains/nokta-dev.keychain-db)
#   NOKTA_KEYCHAIN_PASS  file with the keychain password  (default: ~/.config/nokta-dev/keychain-pass;
#                        empty = do not unlock, e.g. the login keychain holding a Developer ID)
#   NOKTA_SIGN_TIMESTAMP=1  secure timestamp from Apple (network; required for notarization —
#                        scripts/release.sh sets it); default --timestamp=none
#   NOKTA_ALLOW_UNSIGNED_BUILD=1  local ad-hoc build: the dev identity and its keychain are never
#                        touched (no unlock, no keychain prompt possible); the bundle is signed
#                        ad-hoc with the hardened runtime and must still pass codesign --verify
#                        --strict. Not notarized, no stable designated requirement: macOS treats
#                        every such build as a new app for Accessibility. For local runs and
#                        resource measurements, never for distribution.
#   NOKTA_BUILD_DIR      output dir                       (default: build)
#
# Swift optimisation choice (release modes): -Osize -wmo.
#   Measured on the shell skeleton at the time of writing (838 lines of Swift, stubbed core,
#   arm64, strip -x): __TEXT,__text  -O -wmo = 25,252 B   -Osize -wmo = 23,352 B (-7.5 %)
#   (file size identical, 16 KB page granularity; -Onone -g = 114,028 B). The shell is AppKit
#   glue (menu, overlay, HUD, settings); every hot path (AX, layout, hotkeys, event tap) lives in
#   the Zig core, so Swift codegen speed does not touch the p95 < 16 ms target while binary size is
#   a headline goal (< 3 MB; Tiles ships 235 KB arm64). -Osize is the default. Re-measure once the
#   real UI is merged:  NOKTA_SWIFT_OPT="-O -wmo" scripts/build-app.sh  vs the default, then compare
#   `size -m build/Snapline.app/Contents/MacOS/Snapline` and the bench startup numbers.
#   -Xlinker -dead_strip_dylibs was tried: it only drops frameworks the binary never references,
#   the swift overlay dylibs (libswiftMetal, ...) stay, so it is not enabled.
#
# Signing: the self-signed "Nokta Local Dev Signing" identity (see scripts/setup-signing.sh)
# gives a STABLE designated requirement (identifier + certificate root = H"cad4..."), so the
# Accessibility (TCC) grant survives rebuilds. Hardened runtime, NO entitlements. With no
# identity the bundle is signed ad-hoc and the TCC grant is lost on every build (loud warning).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OPT="${NOKTA_OPTIMIZE:-small}"
UNIVERSAL="${NOKTA_UNIVERSAL:-0}"
BUILD_DIR="${NOKTA_BUILD_DIR:-build}"
BUNDLE_ID="com.htahaozlu.snapline"
IDENTITY="${NOKTA_SIGN_IDENTITY:-CAD4DCFDD90BAA202CAC92748C703E23AB1AF401}"
KEYCHAIN="${NOKTA_KEYCHAIN:-$HOME/Library/Keychains/nokta-dev.keychain-db}"
KEYCHAIN_PASS="${NOKTA_KEYCHAIN_PASS-$HOME/.config/nokta-dev/keychain-pass}"
SIGN_TIMESTAMP=(--timestamp=none)
if [ "${NOKTA_SIGN_TIMESTAMP:-0}" = "1" ]; then SIGN_TIMESTAMP=(--timestamp); fi
DEPLOY="14.0"
APP="$BUILD_DIR/Snapline.app"

FRAMEWORKS="AppKit ApplicationServices Carbon CoreFoundation CoreGraphics QuartzCore ServiceManagement"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run_timeout SECONDS cmd... — guards against a GUI keychain prompt hanging a build.
run_timeout() {
    local secs=$1; shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
}

fsize() { stat -f%z "$1"; }
human() { awk -v b="$1" 'BEGIN{ if (b>=1048576) printf "%.2f MB", b/1048576; else printf "%.1f KB", b/1024 }'; }

case "$OPT" in
    debug) SWIFT_OPT_DEFAULT="-Onone -g" ;;
    small) SWIFT_OPT_DEFAULT="-Osize -wmo" ;;
    *) die "NOKTA_OPTIMIZE must be debug|small (got '$OPT'; build.zig pins ReleaseSmall)" ;;
esac
SWIFT_OPT="${NOKTA_SWIFT_OPT:-$SWIFT_OPT_DEFAULT}"

log "config: optimize=$OPT swift='$SWIFT_OPT' universal=$UNIVERSAL${NOKTA_EXTRA_LINK:+ extra-link=set}"
command -v zig >/dev/null   || die "zig not found in PATH"
command -v swiftc >/dev/null || die "swiftc not found (install Xcode command line tools)"

# ---------------------------------------------------------------------------- core library
# build_core PREFIX [extra zig args...]  (always in $OPT; zig's cache keeps it cheap)
build_core() {
    local prefix=$1; shift
    if [ "${NOKTA_CORE_INSTALLED:-0}" = "1" ] && [ -f "$prefix/lib/libnokta.a" ] && [ $# -eq 0 ]; then
        log "core: $prefix/lib/libnokta.a installed by zig build ($OPT)"
        return
    fi
    log "core: zig build ($OPT) → $prefix"
    case "$OPT" in
        debug) zig build --prefix "$prefix" "$@" ;;
        small) zig build -Drelease=true --prefix "$prefix" "$@" ;;
    esac
    [ -f "$prefix/lib/libnokta.a" ] || die "zig build did not produce $prefix/lib/libnokta.a"
}

# The inert core (tools/snapshot only, core/src/inert.zig) must never end up in Snapline.app. It is
# built as libnokta-inert.a and build.zig refuses `app` with -Dinert, but a hand-run script could
# still meet a stray copy, so both the archive and the linked binary are checked.
# nm's output is always read in full before grep: under pipefail, `nm | grep -q` fails when grep
# exits at the first match (SIGPIPE), which would turn these checks into silent passes.
# check_core_lib LIB — the archive about to be linked is not the inert core.
check_core_lib() {
    local syms
    syms="$(nm "$1" 2>/dev/null)" || die "nm cannot read $1"
    if grep -q ' T _nk_inert_core$' <<<"$syms"; then
        die "$1 is the INERT core (snapshot tool only); rebuild it without -Dinert"
    fi
}

# check_real_core BIN — the linked binary imports the real platform APIs and carries no inert marker.
check_real_core() {
    local undef syms sym
    undef="$(nm -u "$1")" || die "nm cannot read $1"
    syms="$(nm "$1" 2>/dev/null)" || die "nm cannot read $1"
    for sym in _AXUIElementCreateApplication _CGEventTapCreate; do
        grep -qx "$sym" <<<"$undef" || die "$1 does not import $sym: not the real core (inert core linked?)"
    done
    if grep -q '_nk_inert_core$' <<<"$syms"; then die "$1 contains the inert core marker"; fi
}

# ---------------------------------------------------------------------------- swift shell
SWIFT_SOURCES=()
while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find app/Sources -name '*.swift' | LC_ALL=C sort)
[ "${#SWIFT_SOURCES[@]}" -gt 0 ] || die "no Swift sources under app/Sources"

# compile_swift ARCH PREFIX OUT EXTRA_LINK
compile_swift() {
    local arch=$1 prefix=$2 out=$3 extra=$4
    local fw=() f
    for f in $FRAMEWORKS; do fw+=(-framework "$f"); done
    check_core_lib "$prefix/lib/libnokta.a"
    log "swiftc [$arch] $SWIFT_OPT (${#SWIFT_SOURCES[@]} files)"
    # shellcheck disable=SC2086  # SWIFT_OPT and extra are intentionally word-split
    swiftc $SWIFT_OPT \
        -swift-version "${NOKTA_SWIFT_VERSION:-5}" \
        -module-name Nokta \
        -target "$arch-apple-macos$DEPLOY" \
        -I "$prefix/include" \
        -L "$prefix/lib" -lnokta \
        "${fw[@]}" \
        -Xlinker -dead_strip \
        $extra \
        -o "$out" \
        "${SWIFT_SOURCES[@]}"
    strip -x "$out"
    check_real_core "$out"
}

mkdir -p "$BUILD_DIR/.work"
HOST_ARCH="$(uname -m)"; [ "$HOST_ARCH" = "arm64" ] || HOST_ARCH="x86_64"

build_core zig-out
compile_swift arm64 zig-out "$BUILD_DIR/.work/Nokta-arm64" "${NOKTA_EXTRA_LINK:-}"
BIN_ARM64="$BUILD_DIR/.work/Nokta-arm64"
BIN="$BIN_ARM64"

if [ "$UNIVERSAL" = "1" ]; then
    # x86_64 core goes to its own prefix so the arm64 zig-out stays untouched
    build_core zig-out-x86_64 -Dtarget=x86_64-macos.14.0
    compile_swift x86_64 zig-out-x86_64 "$BUILD_DIR/.work/Nokta-x86_64" "${NOKTA_EXTRA_LINK_X86_64:-${NOKTA_EXTRA_LINK:-}}"
    BIN="$BUILD_DIR/.work/Nokta-universal"
    lipo -create "$BIN_ARM64" "$BUILD_DIR/.work/Nokta-x86_64" -output "$BIN"
fi

# ---------------------------------------------------------------------------- bundle
VERSION="$(grep -E 'const[[:space:]]+version_string' core/src/root.zig | grep -Eo '"[^"]+"' | head -1 | tr -d '"' || true)"
[ -n "$VERSION" ] || { warn "version_string not found in core/src/root.zig, using 0.0.0"; VERSION="0.0.0"; }

BUILD_NO=""
if TOP="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" && [ "$(cd "$TOP" && pwd -P)" = "$(pwd -P)" ]; then
    BUILD_NO="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
    # Uncommitted changes: CFBundleVersion gets a ".1" so a dirty build never shares the number of
    # the commit it started from (CFBundleVersion allows up to three dot-separated integers).
    if [ -n "$BUILD_NO" ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then BUILD_NO="$BUILD_NO.1"; fi
fi
[ -n "$BUILD_NO" ] || BUILD_NO="$(date -u +%Y%m%d%H%M)"

log "bundle: $APP (version $VERSION, build $BUILD_NO)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapline"
chmod 755 "$APP/Contents/MacOS/Snapline"

sed -e "s|__VERSION__|$VERSION|g" -e "s|__BUILD__|$BUILD_NO|g" app/Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist is not a valid plist"
if grep -q '__[A-Z]*__' "$APP/Contents/Info.plist"; then die "unreplaced placeholder left in Info.plist"; fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The bundle's only resource is the app icon (DESIGN §1, §17.1: no font, PNG, GIF or SVG in
# Contents/Resources; Info.plist is generated above). The icon's SVG reference lives in tools/icon/.
if [ -f app/Resources/AppIcon.icns ]; then
    cp app/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    warn "no AppIcon.icns in app/Resources (Info.plist references AppIcon)"
fi
EXTRA_RESOURCES="$(find app/Resources -mindepth 1 ! -name Info.plist ! -name AppIcon.icns ! -name .DS_Store | LC_ALL=C sort)"
[ -z "$EXTRA_RESOURCES" ] || warn "not bundled (only AppIcon.icns ships): $(echo "$EXTRA_RESOURCES" | tr '\n' ' ')"

# ---------------------------------------------------------------------------- sign
SIGN_MODE="adhoc"
ALLOW_UNSIGNED="${NOKTA_ALLOW_UNSIGNED_BUILD:-0}"
case "$ALLOW_UNSIGNED" in 0|1) ;; *) die "NOKTA_ALLOW_UNSIGNED_BUILD must be 0 or 1 (got '$ALLOW_UNSIGNED')" ;; esac
if [ "$ALLOW_UNSIGNED" = "1" ]; then
    log "codesign: NOKTA_ALLOW_UNSIGNED_BUILD=1 — ad-hoc, the dev identity and keychain are not used"
elif security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    if [ -z "$KEYCHAIN_PASS" ]; then
        : # unlocked by the user's session (login keychain)
    elif [ -r "$KEYCHAIN_PASS" ]; then
        # Password on argv is visible to `ps` for a moment; acceptable for a throwaway dev keychain.
        security unlock-keychain -p "$(cat "$KEYCHAIN_PASS")" "$KEYCHAIN" \
            || warn "could not unlock $KEYCHAIN (signing may prompt or fail)"
    else
        warn "keychain password file $KEYCHAIN_PASS not readable; assuming $KEYCHAIN is unlocked"
    fi
    log "codesign: identity $IDENTITY (hardened runtime, no entitlements)"
    if run_timeout 90 codesign --force --options runtime "${SIGN_TIMESTAMP[@]}" \
            --identifier "$BUNDLE_ID" --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP"; then
        SIGN_MODE="identity"
    else
        warn "codesign with the dev identity failed or timed out (a keychain access prompt?);"
        warn "run: scripts/setup-signing.sh --check   and see its partition-list hint."
    fi
fi
if [ "$SIGN_MODE" != "identity" ]; then
    printf '\n\033[1;31m'
    printf '################################################################################\n'
    printf '#  AD-HOC SIGNATURE: no stable code identity.                                   #\n'
    printf '#  macOS resets the Accessibility permission on EVERY build of this app.        #\n'
    if [ "$ALLOW_UNSIGNED" = "1" ]; then
    printf '#  Requested (NOKTA_ALLOW_UNSIGNED_BUILD=1): local use only, not notarized.     #\n'
    else
    printf '#  Create the dev identity once:  scripts/setup-signing.sh --create             #\n'
    fi
    printf '################################################################################\n'
    printf '\033[0m\n'
    # Strict in every mode: a failed ad-hoc signature stops the build (the bundle would not verify).
    codesign --force --options runtime --timestamp=none --identifier "$BUNDLE_ID" -s - "$APP"
fi

codesign --verify --strict --verbose=2 "$APP"
DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')"
FLAGS="$(codesign -dv "$APP" 2>&1 | sed -n 's/^CodeDirectory .*flags=\(.*\) hashes.*/\1/p')"
log "designated requirement: $DR"
log "code directory flags:   ${FLAGS:-?}"
case "$FLAGS" in *runtime*) ;; *) warn "hardened runtime flag missing from the signature" ;; esac
if [ "$SIGN_MODE" = "identity" ]; then
    case "$DR" in
        *"identifier \"$BUNDLE_ID\""*"certificate root = H\""*) ;;                 # local dev identity
        *"identifier \"$BUNDLE_ID\""*"anchor apple generic"*"subject.OU"*) ;;        # Developer ID
        *) warn "designated requirement is not an 'identifier ... and certificate root' or Developer ID form" ;;
    esac
fi
ENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
[ -z "$ENTS" ] || warn "the signature carries entitlements (none expected)"

# ---------------------------------------------------------------------------- report
EXE="$APP/Contents/MacOS/Snapline"
echo
log "result: $APP"
printf '  binary:   %s (%s bytes)  %s\n' "$(human "$(fsize "$EXE")")" "$(fsize "$EXE")" "$(lipo -archs "$EXE")"
printf '  bundle:   %s  (du)\n' "$(du -sh "$APP" | awk '{print $1}')"
case "$SIGN_MODE" in
    identity)
        if codesign -dv "$APP" 2>&1 | grep -q '^Authority=Developer ID Application'; then
            printf '  signing:  Developer ID (hardened runtime; NOT notarized yet: scripts/release.sh)\n'
        else
            printf '  signing:  dev identity (stable designated requirement, hardened runtime; self-signed, NOT notarized)\n'
        fi ;;
    *) printf '  signing:  ad-hoc%s (hardened runtime; no stable identity: Accessibility must be granted again; NOT notarized)\n' \
              "$([ "$ALLOW_UNSIGNED" = "1" ] && echo ", NOKTA_ALLOW_UNSIGNED_BUILD=1")" ;;
esac
printf '  sha256:   %s  Contents/MacOS/Snapline\n' "$(shasum -a 256 "$EXE" | awk '{print $1}')"
printf '  linked libraries (%s):\n' "$(otool -arch arm64 -L "$EXE" | tail -n +2 | wc -l | tr -d ' ')"
otool -arch arm64 -L "$EXE" | tail -n +2 | awk '{print $1}' | sed -e 's|^|    |' -e 's|/System/Library/Frameworks/||' -e 's|/Versions/[A-Z]/[A-Za-z]*$||' | sort -u
