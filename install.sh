#!/usr/bin/env bash
#
# install.sh — installs OpenShelf.app from the downloaded .dmg, signed on
# this Mac so macOS opens it without warnings and stops asking for the
# Keychain password after every update.
#
#   bash install.sh                     # finds OpenShelf.dmg in Downloads, or the mounted disk
#   bash install.sh ~/Downloads/OpenShelf.dmg
#   bash install.sh /path/to/OpenShelf.app
#   bash install.sh --resign            # only re-sign /Applications/OpenShelf.app
#   bash install.sh --remove-certificate
#
#   OPENSHELF_APP=/path/to/OpenShelf.app   another place than /Applications
#   OPENSHELF_NO_OPEN=1                    don't open it at the end (Homebrew)
#
# The app used to be called Goodreads: an old Goodreads.app (the same app)
# is replaced, and works with --resign too.
#
# What it does, step by step:
#   1. Copies OpenShelf.app into /Applications (quitting it first if it's open).
#   2. Removes the "downloaded from the internet" flag, so Gatekeeper doesn't
#      block an app that isn't notarised by Apple.
#   3. Signs it with a certificate kept in your login keychain, made the first
#      time ("Goodreads Local Signing", self-signed, only ever used on this Mac).
#      A signature that stays the same across versions is what lets
#      "Always Allow" in the Keychain prompt stick.
#
# Nothing is sent anywhere, and nothing needs your administrator password.
set -euo pipefail

APP_NAME="OpenShelf"
OLD_NAME="Goodreads"
BUNDLE_ID="local.goodreads.gui"
TARGET="${OPENSHELF_APP:-${GOODREADS_APP:-/Applications/${APP_NAME}.app}}"
OLD_TARGET="$(dirname "${TARGET}")/${OLD_NAME}.app"
NO_OPEN="${OPENSHELF_NO_OPEN:-${GOODREADS_NO_OPEN:-}}"
# Kept from before the rename, so Macs that have it don't make a second one.
CERT_NAME="Goodreads Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() {
  printf '\033[31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d)"
MOUNTED=""
cleanup() {
  [[ -n "${MOUNTED}" ]] && hdiutil detach -quiet "${MOUNTED}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# --------------------------------------------------------------- options
RESIGN_ONLY=""
SOURCE=""
case "${1:-}" in
  --remove-certificate)
    if security find-certificate -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null 2>&1
    then
      security delete-identity -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null
      bold "Removed '${CERT_NAME}' from your login keychain."
    else
      bold "There's no '${CERT_NAME}' certificate to remove."
    fi
    exit 0
    ;;
  --resign) RESIGN_ONLY=1 ;;
  -h | --help)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *) SOURCE="$1" ;;
esac

# --------------------------------------------------------------- find the app
if [[ -z "${RESIGN_ONLY}" ]]
then
  if [[ -z "${SOURCE}" ]]
  then
    if [[ -d "/Volumes/${APP_NAME}/${APP_NAME}.app" ]]
    then
      SOURCE="/Volumes/${APP_NAME}/${APP_NAME}.app"
    elif [[ -f "${HOME}/Downloads/${APP_NAME}.dmg" ]]
    then
      SOURCE="${HOME}/Downloads/${APP_NAME}.dmg"
    elif [[ -f "${HOME}/Downloads/${OLD_NAME}.dmg" ]]
    then
      SOURCE="${HOME}/Downloads/${OLD_NAME}.dmg"
    else
      die "couldn't find ${APP_NAME}.dmg in Downloads. Pass its path: bash install.sh /path/to/${APP_NAME}.dmg"
    fi
  fi
  [[ -e "${SOURCE}" ]] || die "not found: ${SOURCE}"

  if [[ "${SOURCE}" == *.dmg ]]
  then
    bold "==> Opening $(basename "${SOURCE}")"
    MOUNTED="${WORK}/mount"
    mkdir -p "${MOUNTED}"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "${MOUNTED}" "${SOURCE}" ||
      die "couldn't open ${SOURCE}"
    SOURCE="${MOUNTED}/${APP_NAME}.app"
    [[ -d "${SOURCE}" ]] || SOURCE="${MOUNTED}/${OLD_NAME}.app"
    [[ -d "${SOURCE}" ]] || die "${APP_NAME}.app isn't inside that disk image"
  fi
  [[ -d "${SOURCE}/Contents/MacOS" ]] || die "${SOURCE} doesn't look like an app"

  if pgrep -xq "${APP_NAME}" || pgrep -xq "${OLD_NAME}"
  then
    bold "==> Quitting ${APP_NAME}"
    osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10
    do
      pgrep -xq "${APP_NAME}" || pgrep -xq "${OLD_NAME}" || break
      sleep 0.5
    done
    if pgrep -xq "${APP_NAME}" || pgrep -xq "${OLD_NAME}"
    then
      die "${APP_NAME} is still open. Quit it and run this again."
    fi
  fi

  bold "==> Copying to /Applications"
  SOURCE_PARENT="$(dirname "${SOURCE}")"
  SOURCE_DIR="$(cd "${SOURCE_PARENT}" && pwd)"
  SOURCE_NAME="$(basename "${SOURCE}")"
  if [[ "${SOURCE_DIR}/${SOURCE_NAME}" != "${TARGET}" ]]
  then
    rm -rf "${TARGET}"
    ditto "${SOURCE}" "${TARGET}"
  fi
  # The same app under its old name goes, so there's only one.
  OLD_ID="$(/usr/bin/defaults read "${OLD_TARGET}/Contents/Info" CFBundleIdentifier 2>/dev/null)" || true
  if [[ "${OLD_ID}" == "${BUNDLE_ID}" ]]
  then
    info "removing the old ${OLD_NAME}.app"
    rm -rf "${OLD_TARGET}"
  fi
elif [[ ! -d "${TARGET}" ]] && [[ -d "${OLD_TARGET}" ]]
then
  # --resign on a Mac that still has the app under its old name.
  TARGET="${OLD_TARGET}"
fi
[[ -d "${TARGET}" ]] || die "${TARGET} isn't installed"

# --------------------------------------------------------------- Gatekeeper
bold "==> Removing the 'downloaded from the internet' flag"
xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true

# --------------------------------------------------------------- certificate
if [[ -n "${SIGN_IDENTITY:-}" ]]
then
  IDENTITY="${SIGN_IDENTITY}"
  info "using SIGN_IDENTITY=${IDENTITY}"
else
  if ! security find-certificate -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null 2>&1
  then
    bold "==> Making a signing certificate for this Mac (first time only)"
    cat >"${WORK}/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Goodreads Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # macOS's own openssl (LibreSSL) writes the .p12 format `security import` reads.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -config "${WORK}/cert.cnf" -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null ||
      die "couldn't make the certificate"
    P12_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    /usr/bin/openssl pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
      -name "${CERT_NAME}" -out "${WORK}/id.p12" -passout "pass:${P12_PASS}" 2>/dev/null ||
      die "couldn't package the certificate"
    # -T lets codesign use the key without asking each time.
    security import "${WORK}/id.p12" -k "${KEYCHAIN}" -P "${P12_PASS}" -T /usr/bin/codesign >/dev/null ||
      die "couldn't add the certificate to your login keychain (is it locked?)"
    info "added '${CERT_NAME}' to your login keychain"
  fi
  IDENTITY="$(security find-identity -p codesigning "${KEYCHAIN}" | awk -v name="\"${CERT_NAME}\"" 'index($0, name) {print $2; exit}')"
  [[ -n "${IDENTITY}" ]] || die "the '${CERT_NAME}' certificate is in the keychain but has no private key. Run: bash install.sh --remove-certificate, then this again."
fi

# --------------------------------------------------------------- sign
bold "==> Signing"
cat >"${WORK}/widget.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
    <array><string>/Library/Application Support/GoodreadsGUI/widget/</string></array>
</dict>
</plist>
EOF
xattr -cr "${TARGET}" 2>/dev/null || true
WIDGET="${TARGET}/Contents/PlugIns/GoodreadsWidget.appex"
if [[ -d "${WIDGET}" ]]
then
  codesign --force --sign "${IDENTITY}" --entitlements "${WORK}/widget.entitlements" \
    --generate-entitlement-der "${WIDGET}" 2>/dev/null || die "couldn't sign the widget"
fi
cat >"${WORK}/share.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
EOF
SHARE="${TARGET}/Contents/PlugIns/GoodreadsShare.appex"
if [[ -d "${SHARE}" ]]
then
  codesign --force --sign "${IDENTITY}" --entitlements "${WORK}/share.entitlements" \
    --generate-entitlement-der "${SHARE}" 2>/dev/null || die "couldn't sign the Share extension"
fi
codesign --force --sign "${IDENTITY}" "${TARGET}" 2>/dev/null || die "couldn't sign the app"
codesign --verify --deep "${TARGET}" || die "the signature doesn't check out"
SIGNED_BY="$(codesign -dvv "${TARGET}" 2>&1 | awk -F= '/^Authority/ {print $2; exit}')" || true
info "signed with ${SIGNED_BY:-an ad hoc signature}"

if [[ -n "${NO_OPEN}" ]]
then
  bold "==> Done"
else
  bold "==> Done. Opening ${APP_NAME}"
  open "${TARGET}"
fi
info "The first time, macOS may ask for your login password to let it use the Keychain: choose Always Allow."
