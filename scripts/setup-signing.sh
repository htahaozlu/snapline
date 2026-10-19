#!/usr/bin/env bash
# setup-signing.sh — one-time, idempotent dev signing identity for Nokta.
#
#   scripts/setup-signing.sh [--check]   report only (default); exit 0 if usable, 1 if not
#   scripts/setup-signing.sh --create    create the identity ONLY if it does not exist yet
#         [--add-to-search-list]         additionally append the keychain to the user search list
#                                        (never done implicitly; codesign gets --keychain anyway)
#   scripts/setup-signing.sh --harden    for identities created before hardening: re-import the
#                                        key as NON-extractable, lock the keychain on sleep / after
#                                        1 h, and DELETE the plaintext key.pem + id.p12 (the cert,
#                                        and therefore the designated requirement, stays the same)
#   scripts/setup-signing.sh --remove    delete the dev keychain and ~/.config/nokta-dev (also
#                                        remove Nokta from System Settings › Accessibility)
#
# Security note (docs/SPEC.md §4): TCC grants Accessibility to whatever code satisfies the
# designated requirement. Any program running as this user that can use the signing key can
# sign itself as Nokta and inherit the grant — true of every developer signing identity, which
# is why the key must never sit on disk in plaintext (it could be copied off the machine) and
# why --remove exists for when development stops.
#
# Why: ad-hoc signatures change on every build and macOS then forgets the Accessibility grant.
# A self-signed code-signing certificate gives a STABLE designated requirement:
#     identifier "com.htahaozlu.snapline" and certificate root = H"<sha1 of the cert>"
# so the TCC entry survives rebuilds.
#
# What --create does (nothing here ever touches the login keychain):
#   1. ~/.config/nokta-dev/{cert.pem,keychain-pass}  (0700 dir, 0600 secrets)
#      self-signed RSA-2048 cert, CN "Nokta Local Dev Signing", EKU codeSigning only, 10 years
#   2. a SEPARATE keychain ~/Library/Keychains/nokta-dev.keychain-db (random password, locks on
#      sleep and after 1 h; build-app.sh unlocks it with keychain-pass before signing)
#   3. imports the key there as NON-extractable; key access restricted via the partition list
#      (apple-tool:,apple:,codesign:) so codesign never shows a keychain prompt
#   4. deletes the transient key.pem / id.p12: no plaintext private key stays on disk
#   The certificate is deliberately NOT added to any trust domain: `codesign -s <sha1>
#   --keychain <kc>` works with untrusted self-signed identities (find-identity -v lists it as
#   CSSMERR_TP_NOT_TRUSTED, which is expected and harmless).
#
# Environment: NOKTA_DEV_DIR, NOKTA_KEYCHAIN, NOKTA_SIGN_IDENTITY (expected SHA-1; only used
# for the --check comparison / reporting).

set -euo pipefail

DEV_DIR="${NOKTA_DEV_DIR:-$HOME/.config/nokta-dev}"
KEYCHAIN="${NOKTA_KEYCHAIN:-$HOME/Library/Keychains/nokta-dev.keychain-db}"
EXPECTED="${NOKTA_SIGN_IDENTITY:-CAD4DCFDD90BAA202CAC92748C703E23AB1AF401}"
CN="Nokta Local Dev Signing"
PASS_FILE="$DEV_DIR/keychain-pass"

MODE="check"; ADD_SEARCH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --create) MODE="create" ;;
        --harden) MODE="harden" ;;
        --remove) MODE="remove" ;;
        --add-to-search-list) ADD_SEARCH=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '  [info] %s\n' "$*"; }
PROBLEMS=0

# Echo the SHA-1 of the signing identity named $CN in $KEYCHAIN (empty if none).
identity_hash() {
    [ -f "$KEYCHAIN" ] || return 0
    # Not "-v": a self-signed cert is never "valid" (untrusted) but is perfectly usable by hash.
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v cn="\"$CN\"" '$3 == cn || index($0, cn) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{40}$/) { print $i; exit } }'
}

in_search_list() {
    security list-keychains -d user 2>/dev/null | tr -d ' "' | grep -Fxq "$KEYCHAIN"
}

check() {
    echo "Nokta dev signing — status"
    echo "  config dir : $DEV_DIR"
    echo "  keychain   : $KEYCHAIN"
    echo

    if [ -d "$DEV_DIR" ]; then ok "config dir exists"; else bad "config dir missing"; fi
    for f in cert.pem keychain-pass; do
        if [ -f "$DEV_DIR/$f" ]; then
            mode="$(stat -f%Lp "$DEV_DIR/$f")"
            case "$f" in
                cert.pem) ok "$f present (mode $mode)" ;;
                *) if [ "$mode" = "600" ]; then ok "$f present (mode 600)"; else bad "$f mode is $mode, expected 600"; fi ;;
            esac
        else
            bad "$f missing"
        fi
    done
    for f in key.pem id.p12; do
        if [ -f "$DEV_DIR/$f" ]; then
            note "WARNING: plaintext private key material $DEV_DIR/$f present — run: scripts/setup-signing.sh --harden"
        else
            ok "no $f on disk"
        fi
    done

    if [ -f "$KEYCHAIN" ]; then ok "keychain file exists"; else bad "keychain file missing"; fi

    HASH="$(identity_hash)"
    if [ -n "$HASH" ]; then
        ok "identity \"$CN\" found: $HASH"
        if [ "$HASH" = "$EXPECTED" ]; then ok "matches the SHA-1 build-app.sh expects"
        else bad "SHA-1 differs from the expected $EXPECTED (export NOKTA_SIGN_IDENTITY=$HASH or update build-app.sh)"; fi
        if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$HASH"; then
            note "identity is also trusted (not required)"
        else
            note "identity is not trusted (CSSMERR_TP_NOT_TRUSTED) — expected for a self-signed cert; codesign by hash still works"
        fi
        if [ -f "$DEV_DIR/cert.pem" ]; then
            FP="$(openssl x509 -in "$DEV_DIR/cert.pem" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//; s/://g')"
            if [ "$FP" = "$HASH" ]; then ok "cert.pem fingerprint matches the keychain identity"
            else note "cert.pem fingerprint ($FP) differs from the keychain identity"; fi
        fi
        echo "  expected designated requirement:"
        echo "      identifier \"com.htahaozlu.snapline\" and certificate root = H\"$(printf '%s' "$HASH" | tr 'A-F' 'a-f')\""
    else
        bad "no code-signing identity \"$CN\" in $KEYCHAIN"
    fi

    if in_search_list; then note "keychain is in the user search list (left untouched)"
    else note "keychain is not in the user search list (fine: build-app.sh passes --keychain)"; fi

    if [ -f "$KEYCHAIN" ]; then
        security show-keychain-info "$KEYCHAIN" 2>&1 | sed 's/^/  [info] /'
    fi
    echo
    if [ "$PROBLEMS" -eq 0 ]; then echo "result: usable"; return 0; fi
    echo "result: NOT usable ($PROBLEMS problem(s)) — run: scripts/setup-signing.sh --create"
    return 1
}

create() {
    local existing
    existing="$(identity_hash)"
    if [ -n "$existing" ]; then
        echo "identity \"$CN\" already exists ($existing) in $KEYCHAIN — nothing to do."
        if [ "$ADD_SEARCH" = "1" ] && ! in_search_list; then add_to_search_list; fi
        return 0
    fi

    # Always the system LibreSSL: Homebrew OpenSSL 3 writes PKCS#12 files that `security import`
    # cannot read (AES-256 PBES2 / SHA-256 MAC).
    local SSL=/usr/bin/openssl
    [ -x "$SSL" ] || { echo "error: $SSL not found" >&2; return 1; }

    umask 077
    mkdir -p "$DEV_DIR"; chmod 700 "$DEV_DIR"

    if [ ! -s "$PASS_FILE" ]; then
        "$SSL" rand -hex 16 > "$PASS_FILE"
        chmod 600 "$PASS_FILE"
        echo "created $PASS_FILE"
    fi
    local PASS; PASS="$(cat "$PASS_FILE")"

    if [ ! -s "$DEV_DIR/cert.cnf" ]; then
        cat > "$DEV_DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
O = Nokta (local development)
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    fi
    if [ ! -s "$DEV_DIR/key.pem" ] || [ ! -s "$DEV_DIR/cert.pem" ]; then
        "$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
            -keyout "$DEV_DIR/key.pem" -out "$DEV_DIR/cert.pem" -config "$DEV_DIR/cert.cnf"
        chmod 600 "$DEV_DIR/key.pem"
        echo "created self-signed certificate"
    fi
    "$SSL" pkcs12 -export -inkey "$DEV_DIR/key.pem" -in "$DEV_DIR/cert.pem" \
        -name "$CN" -out "$DEV_DIR/id.p12" -passout "pass:$PASS"
    chmod 600 "$DEV_DIR/id.p12"

    if [ ! -f "$KEYCHAIN" ]; then
        security create-keychain -p "$PASS" "$KEYCHAIN"
        echo "created keychain $KEYCHAIN"
    fi
    security set-keychain-settings -l -u -t 3600 "$KEYCHAIN"   # lock on sleep and after 1 h
    security unlock-keychain -p "$PASS" "$KEYCHAIN"

    import_identity "$PASS"
    rm -f "$DEV_DIR/key.pem" "$DEV_DIR/id.p12"
    echo "deleted the transient key.pem / id.p12 (the key lives only in the keychain, non-extractable)"

    if [ "$ADD_SEARCH" = "1" ] && ! in_search_list; then add_to_search_list; fi

    echo
    PROBLEMS=0
    check
}

# import_identity PASS: id.p12 → keychain, key non-extractable (-x), codesign-only access.
import_identity() {
    local PASS=$1
    # -T: codesign may use the key; the partition list below is what actually silences prompts.
    security import "$DEV_DIR/id.p12" -k "$KEYCHAIN" -P "$PASS" -x -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
}

harden() {
    [ -s "$PASS_FILE" ] || { echo "error: $PASS_FILE missing" >&2; return 1; }
    [ -f "$KEYCHAIN" ] || { echo "error: $KEYCHAIN missing" >&2; return 1; }
    local PASS; PASS="$(cat "$PASS_FILE")"
    local before; before="$(identity_hash)"
    [ -n "$before" ] || { echo "error: no identity \"$CN\" in $KEYCHAIN" >&2; return 1; }
    security set-keychain-settings -l -u -t 3600 "$KEYCHAIN"
    security unlock-keychain -p "$PASS" "$KEYCHAIN"
    if [ -s "$DEV_DIR/id.p12" ]; then
        # Same certificate, same key → same SHA-1 → same designated requirement (TCC grant kept).
        security delete-identity -Z "$before" "$KEYCHAIN" >/dev/null
        import_identity "$PASS"
        local after; after="$(identity_hash)"
        [ "$after" = "$before" ] || { echo "error: identity changed ($before → $after)" >&2; return 1; }
        echo "re-imported $before as non-extractable"
    fi
    rm -f "$DEV_DIR/key.pem" "$DEV_DIR/id.p12"
    echo "deleted plaintext key.pem / id.p12; keychain locks on sleep and after 1 h"
    echo
    PROBLEMS=0
    check
}

remove() {
    if in_search_list; then
        local keep=() line
        while IFS= read -r line; do
            line="${line//\"/}"; line="${line#"${line%%[![:space:]]*}"}"
            [ -n "$line" ] && [ "$line" != "$KEYCHAIN" ] && keep+=("$line")
        done < <(security list-keychains -d user)
        security list-keychains -d user -s "${keep[@]}"
    fi
    [ -f "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN"
    rm -rf "$DEV_DIR"
    echo "removed $KEYCHAIN and $DEV_DIR."
    echo "Also remove Nokta from System Settings › Privacy & Security › Accessibility."
}

add_to_search_list() {
    local current=() line
    while IFS= read -r line; do
        line="${line//\"/}"; line="${line#"${line%%[![:space:]]*}"}"
        [ -n "$line" ] && current+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${current[@]}" "$KEYCHAIN"
    echo "appended $KEYCHAIN to the user keychain search list"
}

case "$MODE" in
    check) check ;;
    create) create ;;
    harden) harden ;;
    remove) remove ;;
esac
