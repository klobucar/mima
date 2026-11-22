#!/usr/bin/env bash
# scripts/sign.sh — sign a built mima binary.
#
# Usage: scripts/sign.sh <signing-identity> <binary> <out-dir>
#
# With identity "-" (the default when no identity is given): ad-hoc sign
# the bare binary WITHOUT entitlements. It runs, but secrets are stored
# without Touch ID protection.
#
# With a real identity: wrap the binary in <out-dir>/Mima.app, embed a
# provisioning profile, and sign it with keychain-access-groups and
# hardened runtime. Why that shape:
#   * Touch ID-gated (.userPresence) items live in the data protection
#     keychain, which requires the keychain-access-groups entitlement.
#   * That entitlement is restricted on macOS. AMFI SIGKILLs any binary
#     that claims it without a provisioning profile authorizing it.
#     That includes ad-hoc and Developer ID binaries without a profile.
#   * A bare Mach-O can't carry a profile, so it goes in an app bundle.
#     Run it through a symlink at <prefix>/bin/mima.
#   * Development profiles pair with "Apple Development" certificates.
#
# Environment overrides:
#   BUNDLE_ID   default com.mima.cli
#   PROFILE     path to a .provisionprofile. Default: auto-discover one
#               for this team that covers BUNDLE_ID, from Xcode's profile
#               directory.
#   TEAM_ID     default: the OU field of the signing certificate. Not the
#               value in parentheses in an "Apple Development: Name (XXXX)"
#               identity; that is a per-person ID.
set -euo pipefail

IDENTITY="${1:?usage: sign.sh <identity|-> <binary> <out-dir>}"
BINARY="${2:?missing binary}"
OUT_DIR="${3:?missing out-dir}"
BUNDLE_ID="${BUNDLE_ID:-com.mima.cli}"
HERE="$(cd "$(dirname "$0")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }
[[ -x "$BINARY" ]] || die "$BINARY not found; run 'swift build -c release' first"

if [[ "$IDENTITY" == "-" ]]; then
  # No entitlements: claiming keychain-access-groups without a profile
  # gets the binary killed at launch.
  codesign --force --sign - --identifier "$BUNDLE_ID" "$BINARY"
  echo "⚠️  Ad-hoc signed $BINARY without entitlements." >&2
  echo "   Secrets will be stored WITHOUT Touch ID protection." >&2
  echo "   For Touch ID: make install SIGNING_IDENTITY=\"Apple Development: <name> (<id>)\"" >&2
  exit 0
fi

# --- Team ID and certificate fingerprints -----------------------------
CERT_PEMS="$(security find-certificate -a -c "$IDENTITY" -p 2>/dev/null || true)"
[[ -n "$CERT_PEMS" ]] || die "no certificate matching '$IDENTITY' (see: security find-identity -v -p codesigning)"
if [[ -z "${TEAM_ID:-}" ]]; then
  TEAM_ID="$(printf '%s\n' "$CERT_PEMS" | openssl x509 -noout -subject 2>/dev/null \
    | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1)"
fi
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "could not read a team ID from '$IDENTITY'; set TEAM_ID=XXXXXXXXXX"

# SHA-1 of every certificate whose name matches, used to check that the
# profile actually authorizes this certificate.
CERT_SHAS="$(security find-certificate -a -Z -c "$IDENTITY" 2>/dev/null | awk '/^SHA-1 hash:/ {print $3}')"

# --- Provisioning profile ---------------------------------------------
TMP="$(mktemp -d -t mima-sign)"
trap 'rm -rf "$TMP"' EXIT

profile_ok() {  # $1 = profile path; prints a rank (2 = exact app ID, 1 = wildcard) if usable
  local p="$1" plist="$TMP/profile.plist" appid team exp now i der sha
  security cms -D -i "$p" > "$plist" 2>/dev/null || return 1
  plutil -extract Platform json -o - "$plist" 2>/dev/null | grep -q '"OSX"' || return 1
  team="$(plutil -extract TeamIdentifier.0 raw -o - "$plist" 2>/dev/null)" || return 1
  [[ "$team" == "$TEAM_ID" ]] || return 1
  exp="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null)" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$exp" > "$now" ]] || return 1
  appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null)" || return 1
  # The profile must include the signing certificate.
  i=0
  while der="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null)"; do
    sha="$(printf '%s' "$der" | base64 -d | shasum -a 1 | awk '{print toupper($1)}')"
    if grep -qx "$sha" <<<"$CERT_SHAS"; then
      if [[ "$appid" == "$TEAM_ID.$BUNDLE_ID" ]]; then echo 2; return 0; fi
      if [[ "$appid" == "$TEAM_ID.*" ]]; then echo 1; return 0; fi
      return 1
    fi
    i=$((i + 1))
  done
  return 1
}

if [[ -z "${PROFILE:-}" ]]; then
  best=0
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    for p in "$dir"/*.provisionprofile; do
      [[ -f "$p" ]] || continue
      if rank="$(profile_ok "$p")" && (( rank > best )); then best=$rank; PROFILE="$p"; fi
    done
  done
  [[ -n "${PROFILE:-}" ]] || die "no valid macOS provisioning profile for $TEAM_ID.$BUNDLE_ID that includes this certificate.
       Create one: in Xcode, build any macOS app target with team $TEAM_ID and automatic signing.
       That generates a 'Mac Team Provisioning Profile: *'. Or pass PROFILE=/path/to/file.provisionprofile"
else
  profile_ok "$PROFILE" >/dev/null || die "PROFILE=$PROFILE is not a valid macOS profile for $TEAM_ID.$BUNDLE_ID with this certificate"
fi
echo "Using profile: $PROFILE"

# --- Bundle -----------------------------------------------------------
APP="$OUT_DIR/Mima.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/mima"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"
sed -e "s/@TEAM_ID@/$TEAM_ID/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" "$HERE/../entitlements.plist" > "$TMP/entitlements.plist"
plutil -lint -s "$TMP/entitlements.plist" "$APP/Contents/Info.plist"

# Hardened runtime and no get-task-allow: other processes running as
# you can't attach a debugger or inject dylibs into mima while it holds
# unlocked secrets.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  --entitlements "$TMP/entitlements.plist" --options runtime --timestamp=none "$APP"

# --- Verify -----------------------------------------------------------
codesign --verify --strict "$APP"
if ! "$APP/Contents/MacOS/mima" --version >/dev/null 2>&1; then
  die "signed binary was rejected at launch (AMFI). Check the profile covers $TEAM_ID.$BUNDLE_ID and this certificate."
fi
echo "✅ Signed $APP (team $TEAM_ID, $BUNDLE_ID, keychain group $TEAM_ID.$BUNDLE_ID)"
