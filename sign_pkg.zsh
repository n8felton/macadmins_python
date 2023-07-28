#!/bin/zsh
# shellcheck shell=bash

readonly BASENAME=${0##*/}
readonly SCRIPTNAME=${BASENAME%.*}
readonly SCRIPTDIR=${0%/$BASENAME}
readonly DATESTRING='%FT%TZ' # ISO8601 (UTC): YYYY-MM-DDTHH:MM:SSZ 
readonly DEFAULT_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

log() {
  echo "[$(date -u +${DATESTRING})]: ${*}" >&1
}

err() {
  echo "[$(date -u +${DATESTRING})]: ${*}" >&2
}

debug() {
  if [[ -n "${DEBUG:+0}" ]]; then
      log "[DEBUG] ${*}"
  fi
}

var_dump() {
  debug "[$1]: $(eval echo -n \$$1)"
}

usage() {
  cat <<USAGE_MSG
  usage: ${SCRIPTNAME} [options]

  -a, --apple-id
          The Apple ID login username you use with Developer ID services.
  -i, --identity
          The name of the identity to use for signing the product archive.
  -k, --keychain
          Specify a keychain to use rather than the default.
  -p, --package
          The package (.pkg) to be signed.
  -t, --team-id
          The team identifier for the Developer Team to be used.
  -w, --password
          App-specific password for your Apple ID.

USAGE_MSG
}

########################################
# Sign the provided macOS Installer product archive (.pkg).
# Arguments:
#   $1 [package]  - The package to be signed.
#   $2 [identity] - The name of the identity to use for signing the product archive.
#   $3 [keychain] - (Optional) Specify a keychain to search for the signing identity.
########################################
sign_package() {
  local package="${1}"
  local identity="${2}"
  local keychain="${3}"
  var_dump package
  var_dump identity
  var_dump keychain
  local args=(--sign "${identity}")
  args+=(--timestamp)
  if [[ -n "${keychain}" ]]; then
    args+=(--keychain "${keychain}")
  fi
  args+=("${package}" "${package%-build*}.pkg")
  debug /usr/bin/productsign "${args[@]}"
  /usr/bin/productsign "${args[@]}"
}

########################################
# Submit the provided macOS Installer product archive (.pkg) to the Apple notary service.
# Arguments:
#   $1 [package]  - The package to be notarized.
#   $2 [apple_id] - The Apple ID login username you use with Developer ID services.
#   $3 [password] - App-specific password for your Apple ID.
#   $4 [team_id]  - The team identifier for the Developer Team to be used.
########################################
notarize_package() {
  local package="${1}"
  local apple_id="${2}"
  local password="${3}"
  local team_id="${4}"
  var_dump package
  var_dump apple_id
  var_dump team_id
  local args=(notarytool submit)
  args+=("${package}")
  args+=(--apple-id "${apple_id}")
  args+=(--password "${password}")
  args+=(--team-id "${team_id}")
  args+=(--wait)
  /usr/bin/xcrun "${args[@]}"
}

########################################
# Attach ticket to notarized package.
# Arguments:
#   $1 [package]  - The package to staple the ticket to.
########################################
staple_ticket() {
  local package="${1}"
  var_dump package
  local args=(stapler staple)
  args+=("${package}")
  debug /usr/bin/xcrun "${args[@]}"
  /usr/bin/xcrun "${args[@]}"
}

main() {
  ropts=(a i p t w)
  while [[ "${#}" -gt 0 ]]; do
    case "${1}" in
    -a|--apple-id) APPLE_ID="${2}"; ropts=(${ropts#a}); shift;;
    -i|--identity) IDENTITY="${2}"; ropts=(${ropts#i}); shift;;
    -k|--keychain) KEYCHAIN="${2}"; ropts=(${ropts#k}); shift;;
    -p|--package)  PACKAGE="${2}";  ropts=(${ropts#p}); shift;;
    -t|--team-id)  TEAM_ID="${2}";  ropts=(${ropts#t}); shift;;
    -w|--password) PASSWORD="${2}"; ropts=(${ropts#w}); shift;;
    *) echo "unknown: $1"; usage; exit 1;;
    esac
  shift
  done

  if (( ${#ropts[@]} )); then
    ropts=(-$^ropts)
    err "Required options are missing: ${ropts[@]}"
    usage
    exit 1
  fi

  # The final package should not have `-signed` (or similar) in the filename so we 
  # reverse the logic and work on a `-build` filename and remove it after signing it.
  BUILD_PACKAGE="${PACKAGE%.*}-build.pkg"
  mv "${PACKAGE}" "${BUILD_PACKAGE}"
  
  sign_package "${BUILD_PACKAGE}" "${IDENTITY}" "${KEYCHAIN:=${DEFAULT_KEYCHAIN}}"
  notarize_package "${PACKAGE}" "${APPLE_ID}" "${PASSWORD}" "${TEAM_ID}" "${KEYCHAIN:=${DEFAULT_KEYCHAIN}}"
  staple_ticket "${PACKAGE}"
}

main "${@}"
