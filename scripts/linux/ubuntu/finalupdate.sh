#!/usr/bin/env bash
#
# finalupdate.sh - last-pass host fixes for Ubuntu images built by Packer.
#
# Runs after apt.sh. It refreshes the package index, applies anything that
# landed since, disables IPv6 at the kernel command line and installs
# PowerShell 7.
#
# The steps are the same as the original script; what changed is:
#
#   * `apt list --upgradeable | apt upgrade -y` did not do what it looks like.
#     apt reads packages from its arguments, never from stdin, so the pipeline
#     discarded the listing and ran a bare upgrade while paying for the listing.
#     It is now a plain `apt-get upgrade`, and `apt-get` is used instead of
#     `apt` because `apt` warns that it has no stable CLI for scripts.
#
#   * `apt-get update --fix-missing` does not retry. --fix-missing applies to
#     install/upgrade, and a transient DNS/hash failure simply ended the build.
#     The refresh now retries a few times before giving up.
#
#   * DEBIAN_FRONTEND alone does not make an upgrade non-interactive: dpkg still
#     stops on modified conffiles and Ubuntu 22.04+ needrestart asks before
#     restarting services. Both are now handled.
#
#   * The GRUB edit was not idempotent (a second run appended
#     "ipv6.disable=1" twice) and silently did nothing if the line was absent
#     or quoted differently. It is now idempotent, reports the resulting line
#     and the regenerated grub.cfg is checked to confirm the parameter arrived.
#     `update-grub` output is no longer thrown away either, so a failure there
#     is visible instead of being mistaken for success.
#
#   * The PowerShell block ran aka.ms/install-powershell.sh from the current
#     directory. That script only accepts -includeide / -interactivetesting /
#     -skip-sudo-check / -preview, so it cannot be told to be non-interactive,
#     its Ubuntu allow-list stops at 22.04 (it exits 1 on anything newer), it
#     needs /etc/lsb-release which minimal cloud images do not ship, and it
#     still calls the removed `apt-key`. PowerShell 7 is now installed from the
#     Microsoft package repository keyed off /etc/os-release, and the result is
#     verified with `pwsh --version`.
#
#     PowerShell is best-effort: a host that cannot get it (an unpublished
#     release, no route to packages.microsoft.com) is logged as a warning and
#     the build carries on. Set POWERSHELL_REQUIRED=1 to make it fatal again.
#
#   * `set -x` ran unconditionally, flooding the Packer log with every
#     expansion, and `set -e` exited silently. Tracing is opt-in now and the
#     failure trap names the line and command that died.
#
# Package cache cleanup is left to cleanup.sh, which already runs
# autoremove/clean.
#
# Usage: ./finalupdate.sh [-v]
#   -v   enable bash command tracing (set -x) for this run
#   -h   show this help
#
# This script is bash, and it has to be run by bash. Packer used to start every
# Ubuntu script with `sh -eux`, and /bin/sh on Ubuntu is dash, which has no
# arrays, no [[ ]], no pipefail and no ERR trap - which is why a 26.04 build
# died with "trap: ERR: bad trap". The Ubuntu build templates invoke bash now,
# and the check below re-executes this script under bash if anything else
# starts it.

# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------
# This has to come before `set -Eeuo pipefail`: on a release whose dash still
# rejects `set -o pipefail` that line is fatal, and the script would never reach
# the re-execution below.
if [ -z "${BASH_VERSION:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    printf '%s: this script needs bash, which is not installed\n' "${0##*/}" >&2
    exit 1
  fi

  if [ ! -r "$0" ]; then
    printf '%s: cannot re-execute under bash: %s is not a readable file\n' "${0##*/}" "$0" >&2
    exit 1
  fi

  # Guard against a `bash` that is not bash, which would re-run this forever.
  if [ -n "${BASH_REEXEC:-}" ]; then
    printf '%s: re-executing under bash did not work\n' "${0##*/}" >&2
    exit 1
  fi

  # Nothing is lost by starting a fresh shell: the options this script needs are
  # set below, and tracing is asked for with -v or TRACE=1. The marker keeps
  # this from becoming a loop if `bash` turns out to be something else.
  exec env BASH_REEXEC=1 bash "$0" "$@"
fi

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly APT_LOCK_TIMEOUT=120        # seconds to wait for /var/lib/dpkg/lock
readonly APT_UPDATE_ATTEMPTS=3       # apt-get update tries before failing
readonly APT_RETRY_DELAY=10          # seconds between update attempts
readonly GRUB_DEFAULT_FILE=/etc/default/grub
readonly GRUB_CFG_FILE=/boot/grub/grub.cfg
readonly IPV6_KERNEL_PARAM='ipv6.disable=1'
readonly POWERSHELL_PACKAGE='powershell'
readonly POWERSHELL_REPO_BASE='https://packages.microsoft.com/config/ubuntu'

# Scratch directory for downloaded installers; removed by the EXIT trap.
WORK_DIR=''

# ---------------------------------------------------------------------------
# Logging / failure reporting
# ---------------------------------------------------------------------------
timestamp() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log()       { printf '[%s] %s\n' "$(timestamp)" "$*"; }
warn()      { printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2; }

die() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  exit 1
}

# `set -e` on its own exits silently: the build dies and the reason is buried
# in the log. This trap reports the failing function, command text, line and
# exit code, once, then exits with the original status.
#
# Note that $BASH_COMMAND is the command *before* expansion, so a variable in
# the command shows as "${var}" rather than its value. The function name and
# exit code pin down the failing step, and the tool itself (apt, dpkg, sed)
# names what it could not do.
on_error() {
  local -r exit_code=$1 line=$2 command=$3
  {
    printf '[%s] ERROR: %s failed (exit %d)\n' "$(timestamp)" "${SCRIPT_NAME}" "${exit_code}"
    printf '  fn  : %s\n' "${FUNCNAME[1]:-main}"
    printf '  line: %s\n' "${line}"
    printf '  cmd : %s\n' "${command}"
  } >&2
  exit "${exit_code}"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

cleanup_work_dir() {
  if [[ -n ${WORK_DIR} && -d ${WORK_DIR} ]]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup_work_dir EXIT

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [-v]

Last-pass host fixes: refreshes the package index, applies pending upgrades,
disables IPv6 at the kernel command line, installs PowerShell 7.

  -v   enable bash command tracing (set -x) for this run
  -h   show this help

Environment:
  TRACE=1                 same as -v
  POWERSHELL_REQUIRED=1   fail the build if PowerShell 7 cannot be installed
                          (default: warn and continue without it)
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
TRACE="${TRACE:-0}"

# PowerShell is optional on these images, so a failure to install it is a
# warning by default. An image that genuinely needs it sets POWERSHELL_REQUIRED=1
# and gets the build stopped instead.
POWERSHELL_REQUIRED="${POWERSHELL_REQUIRED:-0}"
case "${POWERSHELL_REQUIRED}" in
  0|1) ;;
  *) die "POWERSHELL_REQUIRED must be 0 or 1 (got '${POWERSHELL_REQUIRED}')" ;;
esac

while getopts ':vh' option; do
  case "${option}" in
    v) TRACE=1 ;;
    h) usage; exit 0 ;;
    '?') die "unknown option: -${OPTARG} (try -h)" ;;
  esac
done
shift $((OPTIND - 1))

# The original script ran `set -x` unconditionally, which floods the Packer log
# with every expansion - including the whole environment - and buries the lines
# that actually matter. Tracing is opt-in now (./finalupdate.sh -v, or
# TRACE=1), and PS4 is decorated so each traced line names its own file, line
# and function.
if [[ ${TRACE} -eq 1 ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
  set -x
fi

# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------
# Packer's shell provisioner normally runs as root and minimal cloud images do
# not always ship `sudo`, so only reach for it when we are not already root.
if [[ ${EUID} -eq 0 ]]; then
  readonly -a SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "not running as root and sudo is not installed"
  readonly -a SUDO=(sudo)
fi

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
# /etc/os-release is part of the systemd/base-files package set and is present
# on every supported release, unlike /etc/lsb-release which needs the optional
# lsb-release package. The original PowerShell installer depended on the latter.
[[ -r /etc/os-release ]] || die '/etc/os-release is not readable - unsupported platform'
# shellcheck source=/dev/null
. /etc/os-release
readonly OS_ID="${ID:-}"
readonly OS_VERSION_ID="${VERSION_ID:-}"

# ---------------------------------------------------------------------------
# Unattended apt/dpkg
# ---------------------------------------------------------------------------
# DEBIAN_FRONTEND alone is not enough to make an upgrade non-interactive: dpkg
# still stops on modified conffiles and Ubuntu 22.04+ needrestart asks before
# restarting services. The options below keep the shipped config on a conflict
# instead of prompting, and NEEDRESTART_MODE lets services restart automatically.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a     # Ubuntu 22.04+: restart services, never prompt
export UCF_FORCE_CONFFOLD=1   # keep existing config for ucf-managed files

readonly -a APT_OPTS=(
  -q
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"   # wait out a competing apt run
)

readonly -a APT_INSTALL_OPTS=(
  -y
  "${APT_OPTS[@]}"
)

# ---------------------------------------------------------------------------
# apt wrappers
# ---------------------------------------------------------------------------
# Refreshes the package lists, retrying transient failures. Returns non-zero
# rather than aborting so the caller can decide: the main flow treats a broken
# index as fatal, the optional PowerShell install does not.
apt_refresh() {
  # `--fix-missing` only applies to install/upgrade; for the index it is a
  # no-op. The failure modes that actually bite a build - a slow mirror, a
  # transient DNS error, a hash mismatch - are all transient, so retry instead
  # of letting one flaky response end the run.
  local attempt=1
  while :; do
    log "Refreshing package lists (attempt ${attempt}/${APT_UPDATE_ATTEMPTS}) ..."
    if "${SUDO[@]}" apt-get update "${APT_OPTS[@]}"; then
      return 0
    fi
    if ((attempt >= APT_UPDATE_ATTEMPTS)); then
      warn "apt-get update is still failing after ${APT_UPDATE_ATTEMPTS} attempts"
      return 1
    fi
    warn "apt-get update failed; retrying in ${APT_RETRY_DELAY}s ..."
    sleep "${APT_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done
}

apt_upgrade() {
  # Plain `upgrade` is deliberate: it never removes packages, matching apt.sh.
  # It will hold back anything that needs a new dependency, which is the safe
  # outcome for an image that is about to be sealed. Use `dist-upgrade` here
  # instead if a later release of the base image ever needs that.
  log 'Applying package upgrades ...'
  "${SUDO[@]}" apt-get upgrade "${APT_INSTALL_OPTS[@]}"
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
download_file() {
  local -r url=$1 destination=$2

  if command -v curl >/dev/null 2>&1; then
    # -f fails on an HTTP error instead of saving an error page, -S still
    # reports the reason, --retry rides out a flaky mirror.
    curl -fsSL --retry 3 --retry-delay 5 -o "${destination}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=30 -O "${destination}" "${url}"
  else
    warn 'neither curl nor wget is installed'
    return 1
  fi
}

# ---------------------------------------------------------------------------
# GRUB / IPv6
# ---------------------------------------------------------------------------
# Appends a kernel parameter to GRUB_CMDLINE_LINUX in /etc/default/grub.
#
# The original one-liner only matched a line whose value already ended in a
# quote, appended on every run whether or not the parameter was there, and did
# not report a thing when it matched nothing. This version is idempotent and
# logs the resulting line.
set_grub_kernel_param() {
  local -r param=$1

  if [[ ! -f ${GRUB_DEFAULT_FILE} ]]; then
    warn "${GRUB_DEFAULT_FILE} does not exist - cannot set '${param}'"
    return 1
  fi

  if grep -q -- "${param}" "${GRUB_DEFAULT_FILE}"; then
    log "'${param}' is already set in ${GRUB_DEFAULT_FILE} - leaving it as it is."
    return 0
  fi

  local -r line_re="^([[:space:]]*GRUB_CMDLINE_LINUX=)\"(.*)\"[[:space:]]*$"
  if grep -qE "${line_re}" "${GRUB_DEFAULT_FILE}"; then
    # Append inside the existing quotes: GRUB_CMDLINE_LINUX="x" -> "x <param>"
    sed -i -E "s|${line_re}|\1\"\2 ${param}\"|" "${GRUB_DEFAULT_FILE}"
    # The append above leaves a stray leading space when the list was empty:
    # GRUB_CMDLINE_LINUX="" -> " <param>"
    sed -i -E 's|^([[:space:]]*GRUB_CMDLINE_LINUX=)"[[:space:]]+|\1"|' "${GRUB_DEFAULT_FILE}"
  else
    # No usable GRUB_CMDLINE_LINUX line (removed or commented out): add one.
    printf 'GRUB_CMDLINE_LINUX="%s"\n' "${param}" >> "${GRUB_DEFAULT_FILE}"
  fi

  # Confirm the edit landed before reporting success. This function is called
  # from an `if`, so `set -e` is disabled inside it (shellcheck SC2310): a write
  # that failed, or a sed that matched nothing, would otherwise carry on and be
  # logged as if it had worked.
  grep -q -- "${param}" "${GRUB_DEFAULT_FILE}" ||
    die "could not add '${param}' to ${GRUB_DEFAULT_FILE}"

  log "Set in ${GRUB_DEFAULT_FILE}: $(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX=' "${GRUB_DEFAULT_FILE}" | tail -n 1)"
}

regenerate_grub_config() {
  # Output is no longer redirected to /dev/null: hiding it made a failed or
  # skipped GRUB regeneration look identical to a successful one.
  if command -v update-grub >/dev/null 2>&1; then
    "${SUDO[@]}" update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    "${SUDO[@]}" grub-mkconfig -o "${GRUB_CFG_FILE}"
  else
    die 'neither update-grub nor grub-mkconfig is available'
  fi
}

verify_grub_kernel_param() {
  # Regenerating the boot configuration is what makes the edit real, so confirm
  # the parameter actually landed in it rather than trusting the exit code.
  local -r param=$1

  if [[ ! -f ${GRUB_CFG_FILE} ]]; then
    warn "${GRUB_CFG_FILE} does not exist - cannot confirm '${param}' reached the boot configuration"
    return 0
  fi

  grep -q -- "${param}" "${GRUB_CFG_FILE}" ||
    die "'${param}' is missing from ${GRUB_CFG_FILE} - the GRUB edit did not take effect"
  log "Verified '${param}' is present in ${GRUB_CFG_FILE}."
}

# ---------------------------------------------------------------------------
# PowerShell 7 (best-effort)
# ---------------------------------------------------------------------------
# Reports every failure and returns non-zero instead of aborting, so the caller
# decides whether a host without PowerShell is acceptable. Each step that can
# fail is tested rather than left bare, otherwise `set -e` would abort the build
# before the caller ever sees the return value.
install_powershell() {
  if command -v pwsh >/dev/null 2>&1; then
    log "PowerShell is already installed: $(pwsh --version)"
    return 0
  fi

  if [[ ${OS_ID} != ubuntu ]]; then
    warn "PowerShell install expects Ubuntu, but this host reports ID='${OS_ID}' - skipping"
    return 1
  fi

  local -r config_deb_url="${POWERSHELL_REPO_BASE}/${OS_VERSION_ID}/packages-microsoft-prod.deb"

  WORK_DIR="$(mktemp -d)"
  local -r config_deb_file="${WORK_DIR}/packages-microsoft-prod.deb"

  log "Installing ${POWERSHELL_PACKAGE} 7 from the Microsoft package repository (Ubuntu ${OS_VERSION_ID}) ..."

  # -f in download_file means a missing 404 page arrives as a failure, so an
  # unsupported release produces this message rather than a dpkg error.
  if ! download_file "${config_deb_url}" "${config_deb_file}"; then
    warn "could not download ${config_deb_url} - Ubuntu ${OS_VERSION_ID} may not be published by the Microsoft package repository"
    return 1
  fi

  # The .deb only drops the repository list and signing key in place; installing
  # it is equivalent to the removed `apt-key add` step, without the warning.
  if ! "${SUDO[@]}" dpkg -i "${config_deb_file}"; then
    warn "could not install the Microsoft repository package (${config_deb_file})"
    return 1
  fi

  # The new repository is only usable once the index has been refreshed.
  if ! apt_refresh; then
    warn 'could not refresh the package index for the Microsoft repository'
    return 1
  fi

  if ! "${SUDO[@]}" apt-get install "${APT_INSTALL_OPTS[@]}" "${POWERSHELL_PACKAGE}"; then
    warn "could not install '${POWERSHELL_PACKAGE}' from the Microsoft repository"
    return 1
  fi

  if ! command -v pwsh >/dev/null 2>&1; then
    warn "the '${POWERSHELL_PACKAGE}' package installed but 'pwsh' is not on PATH"
    return 1
  fi

  log "PowerShell installed: $(pwsh --version)"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  command -v apt-get >/dev/null 2>&1 ||
    die 'apt-get not found - this script targets Debian/Ubuntu'

  # A broken package index blocks every later step, so this one stays fatal.
  apt_refresh || die 'could not refresh the package index'

  apt_upgrade

  log 'Disabling IPv6 in the GRUB kernel command line ...'
  # A missing or unreadable /etc/default/grub is reported by the helper; it does
  # not need to abort the rest of the run.
  if set_grub_kernel_param "${IPV6_KERNEL_PARAM}"; then
    regenerate_grub_config
    verify_grub_kernel_param "${IPV6_KERNEL_PARAM}"
  fi

  # PowerShell is best-effort: an image that cannot reach the Microsoft
  # repository is degraded, not broken, so it warns by default and only stops
  # the build when POWERSHELL_REQUIRED=1.
  if install_powershell; then
    :
  elif [[ ${POWERSHELL_REQUIRED} -eq 1 ]]; then
    die 'PowerShell 7 could not be installed and POWERSHELL_REQUIRED=1'
  else
    warn 'PowerShell 7 was not installed - continuing without it'
  fi

  printf '%s\n' \
    '####################################################' \
    'Updates and fixes have completed' \
    '####################################################'
}

main "$@"
