#!/usr/bin/env bash
# Imports Prism's stable self-signed code-signing identity into a temporary keychain (CI only).
#
# Why: ad-hoc signatures change with every build, so macOS privacy permissions (camera,
# microphone, system-audio capture, speech) are keyed to a different "app" after every update
# and the user gets re-prompted. Signing every build with the same certificate keeps the
# designated requirement stable, so permissions survive updates.
#
# Inputs (GitHub secrets, passed as env): PRISM_SIGNING_P12 (base64 PKCS#12), PRISM_SIGNING_PASSWORD.
# Outputs (appended to $GITHUB_ENV): PRISM_SIGN_IDENTITY, PRISM_SIGN_KEYCHAIN.
# Missing secrets or any failure → exits 0 without exporting anything (builds fall back to ad-hoc).
set -uo pipefail

IDENTITY_NAME="Prism Code Signing"

if [[ -z "${PRISM_SIGNING_P12:-}" || -z "${PRISM_SIGNING_PASSWORD:-}" ]]; then
  echo "No signing identity configured; builds will be ad-hoc signed."
  exit 0
fi
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ci-import-signing.sh must run on macOS" >&2
  exit 0
fi

TMPDIR_SIGN="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$TMPDIR_SIGN/prism-signing.keychain-db"
P12="$TMPDIR_SIGN/prism-signing.p12"
CERT="$TMPDIR_SIGN/prism-signing.pem"
KC_PASS="$(uuidgen)"

fail() {
  echo "warning: $1 — falling back to ad-hoc signing" >&2
  rm -f "$P12"
  exit 0
}

printf '%s' "$PRISM_SIGNING_P12" | base64 --decode > "$P12" 2>/dev/null || fail "could not decode PRISM_SIGNING_P12"

security create-keychain -p "$KC_PASS" "$KEYCHAIN" || fail "could not create keychain"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" || fail "could not unlock keychain"
security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$PRISM_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null \
  || fail "could not import the signing identity"
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null \
  || fail "could not set the key partition list"

# Put the temporary keychain on the user search list (keeping the existing ones).
EXISTING=()
while IFS= read -r line; do
  line="${line//\"/}"
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -n "$line" ]] && EXISTING+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${EXISTING[@]}" || fail "could not update the keychain search list"

# Trust the self-signed certificate for code signing (runner-local; runners are ephemeral).
if security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN" > "$CERT" 2>/dev/null; then
  sudo -n security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$CERT" \
    || echo "note: could not mark the certificate trusted (codesign usually works without it)"
fi

if ! security find-identity -p codesigning "$KEYCHAIN" | grep -q "$IDENTITY_NAME"; then
  fail "identity '$IDENTITY_NAME' not found after import"
fi
security find-identity -p codesigning "$KEYCHAIN" | sed -n '1,4p'

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "PRISM_SIGN_IDENTITY=$IDENTITY_NAME"
    echo "PRISM_SIGN_KEYCHAIN=$KEYCHAIN"
  } >> "$GITHUB_ENV"
fi
echo "Signing identity '$IDENTITY_NAME' ready."
