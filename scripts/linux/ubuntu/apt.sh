#!/usr/bin/env bash
#
# apt.sh - baseline package provisioning for Ubuntu hosts.
#
# Baked into the image by Packer and safe to re-run.
# The package set and the "refresh -> upgrade -> install" flow are unchanged
# from the original script; what changed is prompt handling, failure
# reporting, tracing and verification.
#
# Usage: ./apt.sh [-v]
#   -v   enable bash command tracing (set -x) for this run
#
# This script is bash, and it has to be run by bash. Packer used to start every
# Ubuntu script with `sh -eux`, and /bin/sh on Ubuntu is dash, which has no
# arrays, no [[ ]], no pipefail and no ERR trap. The Ubuntu build invokes bash,
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
readonly APT_LOCK_TIMEOUT=120   # seconds to wait for /var/lib/dpkg/lock

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
# Note that $BASH_COMMAND is the command *before* expansion, so it shows
# "${PACKAGES_REQUIRED[@]}" rather than the package list. The exit code and
# function name pin down the failing step, and apt itself names the package it
# could not install.
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

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [-v]

Provisions the baseline Ubuntu package set (refreshes the index, applies
upgrades, installs service packages, verifies the result).

  -v   enable bash command tracing (set -x) for this run
  -h   show this help
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
TRACE="${TRACE:-0}"

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
# that actually matter. Tracing is opt-in now (./apt.sh -v, or TRACE=1), and
# PS4 is decorated so each traced line names its own file, line and function.
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
# Unattended apt/dpkg
# ---------------------------------------------------------------------------
# DEBIAN_FRONTEND alone is not enough to make upgrades non-interactive: dpkg
# still stops on modified conffiles (samba-common, sssd, chrony all ship them)
# and Ubuntu 22.04+ needrestart asks before restarting services. The options
# below keep the shipped config on a conflict instead of prompting, and
# NEEDRESTART_MODE lets services restart automatically.
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
  # Uncomment to cut image size, but re-test the AD join first - realmd and
  # sssd-ad rely on packages that are only pulled in as recommendations:
  # --no-install-recommends
)

# ---------------------------------------------------------------------------
# Package set
# ---------------------------------------------------------------------------
# Packages the image must ship with: any failure fails the build.
readonly -a PACKAGES_REQUIRED=(
  # base management
  update-manager-core
  # networking / DNS tools and monitoring agents
  netplan.io
  bind9-utils
  snmp
  # time sync
  chrony
  # Active Directory integration
  samba-common
  samba-common-bin
  sssd
  sssd-ad
  sssd-tools
  realmd
  oddjob
  oddjob-mkhomedir
  adcli
  # Deliberately not installed:
  #   network-manager  - netplan.io owns the interface configuration here
  #   krb5-user        - its debconf prompt needs a realm/DC answer
  #   selinux-*        - SELinux is not used on these images
)

# Not present in every Ubuntu release/component: report and continue.
readonly -a PACKAGES_OPTIONAL=(
  chkservice
)

# ---------------------------------------------------------------------------
# apt wrappers
# ---------------------------------------------------------------------------
apt_refresh() {
  # `apt-get update` never prompts, so the original `-y` was noise.
  log 'Refreshing package lists ...'
  "${SUDO[@]}" apt-get update "${APT_OPTS[@]}"
}

apt_upgrade() {
  log 'Applying package upgrades ...'
  "${SUDO[@]}" apt-get upgrade "${APT_INSTALL_OPTS[@]}"
}

apt_is_installed() {
  # dpkg-query exits 1 for an unknown package, which would trip `set -e`
  # inside a command substitution, so the status is captured defensively.
  local status
  status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || status=''
  [[ ${status} == 'install ok installed' ]]
}

apt_install_required() {
  # One transaction instead of the original sixteen: apt resolves the
  # dependency graph once and dpkg configures each package once. It is several
  # times faster and cannot leave the system half-configured part way through
  # the list the way sequential installs can.
  log "Installing ${#PACKAGES_REQUIRED[@]} required packages ..."
  "${SUDO[@]}" apt-get install "${APT_INSTALL_OPTS[@]}" "${PACKAGES_REQUIRED[@]}"
}

apt_install_optional() {
  local package
  for package in "${PACKAGES_OPTIONAL[@]}"; do
    if apt_is_installed "${package}"; then
      log "Optional package already installed: ${package}"
      continue
    fi
    # A command whose status is tested by `if` does not trip `set -e`/ERR, so
    # this stays best-effort - but the failure is reported with its exit code
    # instead of being swallowed by the original `|| echo`.
    if "${SUDO[@]}" apt-get install "${APT_INSTALL_OPTS[@]}" "${package}"; then
      log "Optional package installed: ${package}"
    else
      warn "optional package '${package}' could not be installed - continuing"
    fi
  done
}

verify_installed_packages() {
  # Exit codes alone do not prove provisioning worked: confirm each required
  # package really reports as installed before declaring success.
  local -a missing=()
  local package
  for package in "${PACKAGES_REQUIRED[@]}"; do
    apt_is_installed "${package}" || missing+=("${package}")
  done

  if ((${#missing[@]} > 0)); then
    die "required packages not installed: ${missing[*]}"
  fi
  log "Verified all ${#PACKAGES_REQUIRED[@]} required packages are installed."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  command -v apt-get >/dev/null 2>&1 ||
    die 'apt-get not found - this script targets Debian/Ubuntu'

  apt_refresh
  apt_upgrade
  apt_install_required
  apt_install_optional
  verify_installed_packages

  printf '%s\n' \
    '####################################################' \
    'Updates and installs have completed' \
    '####################################################'
}

main "$@"
