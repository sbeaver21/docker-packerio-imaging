#!/usr/bin/env bash
#
# update-packages.sh - fully update and patch a Photon OS guest, then prove it.
#
# Last provisioner of the Photon OS image builds (builds/linux/photon/4 and
# builds/linux/photon/5). This is the step that makes the template Packer seals
# "fully updated and patched": every package the build installed before it -
# the kickstart package set, and on Photon OS 5 the Docker Engine, the Compose
# plugin and the Kubernetes packages baked in by bake-migration-kit.sh - is
# brought to the newest version the configured Photon repositories carry at the
# moment the image is captured.
#
# It runs last on purpose. A provisioner that installed a package after this
# script would leave that package unpatched, and one that cleared the package
# cache before it would cost a second full metadata download.
#
# What it does:
#
#   1. refreshes the repository metadata, retrying a slow or flaky mirror
#      instead of failing the build on the first bad response;
#   2. upgrades the installed packages, then distro-syncs them against the
#      repositories. The sync matters as much as the upgrade on Photon: a
#      security fix is frequently shipped as a rebuild whose version string did
#      not move, which `upgrade` alone will not pick up. The dependencies the
#      upgrades obsoleted are then removed;
#   3. repeats that until tdnf reports nothing left to do, bounded by
#      PHOTON_PATCH_MAX_ROUNDS, so a repository publishing during the build
#      cannot spin forever;
#   4. verifies the result. `tdnf check-update` must report no pending updates
#      or the build fails. A template that silently ships unpatched is worse
#      than a build that stops and says so, and tdnf does not make that
#      distinction easy: a repository it cannot reach is dropped with a single
#      "Disabling Repo" line and every later step still exits 0, so "nothing to
#      do" and "I could not ask" look identical unless the output is read. It is
#      read here, and a dropped repository - or an image with no enabled
#      repository at all - fails the build instead of being reported as clean.
#
# It deliberately does not touch the boot loader. Photon's `linux` package
# maintains /boot/grub2/grub.cfg itself when the kernel is upgraded, and a
# hand-written grub2-mkconfig call here could only make that worse. The kernels
# that ended up on disk are reported instead, so the build log shows what the
# clones will boot.
#
# This script is bash, and it has to be run by bash: it uses arrays, [[ ]],
# `set -o pipefail` and an ERR trap, none of which exist in dash or ash. The
# templates invoke it as
#
#     {{.Vars}} sudo -S -E bash -eux '{{.Path}}'
#
# and the check below re-executes the script under bash if anything else starts
# it.
#
# Usage: ./update-packages.sh [-v] [-h]
#   -v   enable bash command tracing (set -x) for this run
#   -h   show this help
#
# Environment overrides:
#   TRACE=1                        same as -v
#   PHOTON_PATCH_MAX_ROUNDS=<n>    upgrade rounds before giving up (default 5)
#   PHOTON_PATCH_ATTEMPTS=<n>      metadata-refresh attempts (default 3)
#   PHOTON_PATCH_STRICT=0          do not fail the build when the system cannot
#                                  be proven current: the repository being
#                                  unreachable and updates still pending become
#                                  loud warnings and the image is reported as
#                                  UNVERIFIED. Default 1 (fail the build).

# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------
# This has to come before `set -Eeuo pipefail`: on a shell whose `set -o
# pipefail` is fatal that line would end the run before the re-execution below
# was reached.
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

  exec env BASH_REEXEC=1 bash "$0" "$@"
fi

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly TDNF_BIN="/usr/bin/tdnf"
readonly OS_RELEASE_FILE="/etc/os-release"

# Packages whose absence would make the sealed template undeployable rather
# than merely outdated. open-vm-tools is the one that matters: the vsphere-iso
# builder discovers the guest's address, and therefore reaches the communicator
# at all, through VMware Tools. Photon's `minimal` package set already carries
# it; the check is here so a build that somehow lost it says so.
readonly -a ESSENTIAL_PACKAGES=( open-vm-tools )

readonly PHOTON_PATCH_MAX_ROUNDS="${PHOTON_PATCH_MAX_ROUNDS:-5}"
readonly PHOTON_PATCH_ATTEMPTS="${PHOTON_PATCH_ATTEMPTS:-3}"
readonly PHOTON_PATCH_STRICT="${PHOTON_PATCH_STRICT:-1}"
readonly REFRESH_RETRY_DELAY=10

# ---------------------------------------------------------------------------
# Logging / failure reporting
# ---------------------------------------------------------------------------
timestamp() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log()       { printf '[%s] %s: %s\n' "$(timestamp)" "${SCRIPT_NAME}" "$*"; }
warn()      { printf '[%s] %s: WARNING: %s\n' "$(timestamp)" "${SCRIPT_NAME}" "$*" >&2; }

die() {
  printf '[%s] %s: ERROR: %s\n' "$(timestamp)" "${SCRIPT_NAME}" "$*" >&2
  exit 1
}

# `set -e` on its own exits silently, leaving the Packer log to stop with no
# explanation of which step died. This trap names the function, the line and the
# command, once, then exits with the original status.
#
# Note that $BASH_COMMAND is the command *before* expansion, so a variable in
# the command shows as "${var}" rather than its value. The function name and the
# exit code pin down the failing step, and tdnf itself names the package it
# could not resolve.
on_error() {
  local -r exit_code=$1 line=$2 command=$3
  {
    printf '[%s] %s: ERROR: failed (exit %d)\n' "$(timestamp)" "${SCRIPT_NAME}" "${exit_code}"
    printf '  fn  : %s\n' "${FUNCNAME[1]:-main}"
    printf '  line: %s\n' "${line}"
    printf '  cmd : %s\n' "${command}"
  } >&2
  exit "${exit_code}"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Capturing tdnf
# ---------------------------------------------------------------------------
# tdnf reports success even when it has just given up on a repository it cannot
# reach: it prints "Disabling Repo" once, runs every later step as "Nothing to
# do" and exits 0, and `check-update` then reports nothing pending - which is
# true only of the repository set it just discarded. A build that trusted that
# answer would be sealed unpatched while its log claimed it was fully patched,
# so the output of every tdnf call is captured and scanned, not merely streamed.
TDNF_LOG=""

remove_tdnf_log() {
  if [[ -n "${TDNF_LOG}" && -e "${TDNF_LOG}" ]]; then
    rm -f -- "${TDNF_LOG}"
  fi
}
trap remove_tdnf_log EXIT

# run_tdnf <args...>
# Streams tdnf's output into the build log while capturing it, and returns
# tdnf's own exit status.
run_tdnf() {
  if [[ -z "${TDNF_LOG}" ]]; then
    TDNF_LOG="$(mktemp -t photon-patch.XXXXXX 2>/dev/null || printf '%s' "/tmp/photon-patch.$$.log")"
  fi
  : > "${TDNF_LOG}"

  local status=0
  # tee keeps the build log live, which matters for an upgrade that runs for
  # minutes; the capture is what the checks below actually read.
  if command -v tee >/dev/null 2>&1; then
    "${SUDO[@]}" "${TDNF_BIN}" "$@" 2>&1 | tee "${TDNF_LOG}" || status=$?
  else
    "${SUDO[@]}" "${TDNF_BIN}" "$@" > "${TDNF_LOG}" 2>&1 || status=$?
    cat -- "${TDNF_LOG}"
  fi
  return "${status}"
}

# repository_was_dropped
# True when the captured tdnf run shows tdnf giving up on a repository.
repository_was_dropped() {
  grep -qE 'Disabling Repo|Failed to synchronize cache' "${TDNF_LOG}" 2>/dev/null
}

# enabled_repository_count
# The number of repositories tdnf reports as enabled. It has to be non-zero:
# with every repository disabled - or every one of them dropped - tdnf has
# nothing to ask, so "nothing is pending" would mean nothing at all. The
# listing's header line is dropped and the rest counted; there is no awk on a
# minimal Photon image.
enabled_repository_count() {
  "${SUDO[@]}" "${TDNF_BIN}" repolist enabled 2>/dev/null \
    | tail -n +2 \
    | grep -c '[^[:space:]]' \
    || true
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [-v] [-h]

Brings a VMware Photon OS guest fully up to date, and fails the build if it
cannot prove the system is current.

  -v   enable bash command tracing (set -x) for this run
  -h   show this help

Environment:
  TRACE=1                       same as -v
  PHOTON_PATCH_MAX_ROUNDS=<n>   upgrade rounds before giving up (default 5)
  PHOTON_PATCH_ATTEMPTS=<n>     metadata-refresh attempts (default 3)
  PHOTON_PATCH_STRICT=0         warn instead of failing when the system cannot
                                be proven current (default 1)
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
TRACE="${TRACE:-0}"

parse_arguments() {
  while getopts ':vh' option; do
    case "${option}" in
      v) TRACE=1 ;;
      h) usage; exit 0 ;;
      '?') die "unknown option: -${OPTARG} (try -h)" ;;
    esac
  done
  shift $((OPTIND - 1))

  if [[ "$#" -gt 0 ]]; then
    die "unexpected argument: $1 (try -h)"
  fi
}

# validate_settings
# A mistyped round or attempt count must stop the run here rather than turn into
# an arithmetic error half way through a patch.
validate_settings() {
  local name value
  for name in PHOTON_PATCH_MAX_ROUNDS PHOTON_PATCH_ATTEMPTS PHOTON_PATCH_STRICT; do
    value="${!name}"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
      die "${name} must be a whole number (got '${value}')"
    fi
  done

  if (( PHOTON_PATCH_MAX_ROUNDS < 1 )); then
    die "PHOTON_PATCH_MAX_ROUNDS must be at least 1"
  fi
  if (( PHOTON_PATCH_ATTEMPTS < 1 )); then
    die "PHOTON_PATCH_ATTEMPTS must be at least 1"
  fi
  if (( PHOTON_PATCH_STRICT != 0 && PHOTON_PATCH_STRICT != 1 )); then
    die "PHOTON_PATCH_STRICT must be 0 or 1 (got '${PHOTON_PATCH_STRICT}')"
  fi
}

# SUDO is empty when the script already runs as root - the Packer case, where the
# template invokes it through sudo - and holds `sudo` when an operator runs it as
# an ordinary user. require_root() fills it in after the options are parsed:
# resolving it here, at load time, would make `-h` fail on a non-root host before
# it could print the help the operator asked for. (Photon OS ships bash 5, where
# an empty array expands safely under `set -u`.)
SUDO=()

# require_root
# Called from main() once the options are known, so --help still works for a
# non-root operator.
require_root() {
  if [[ ${EUID} -eq 0 ]]; then
    SUDO=()
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "must run as root, and sudo is not installed"
  fi

  SUDO=(sudo)
}

# require_photon
# /etc/os-release is present on every Photon release; check it rather than
# assume, so a script copied into the wrong build tree stops immediately instead
# of running tdnf against a different distribution's repositories.
require_photon() {
  [[ -r "${OS_RELEASE_FILE}" ]] || die "${OS_RELEASE_FILE} is not readable - unsupported platform"

  local id=""
  id="$(sed -n 's/^ID="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "${OS_RELEASE_FILE}" | head -n 1)"
  if [[ "${id}" != "photon" ]]; then
    die "this script targets VMware Photon OS, but ${OS_RELEASE_FILE} reports ID='${id:-unknown}'"
  fi

  [[ -x "${TDNF_BIN}" ]] || die "tdnf not found at ${TDNF_BIN} - this script targets VMware Photon OS"
}

# os_version
# The VERSION field of /etc/os-release (e.g. 4.0 or 5.0), for the log.
os_version() {
  local value=""
  value="$(sed -n 's/^VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "${OS_RELEASE_FILE}" | head -n 1)"
  printf '%s' "${value:-unknown}"
}

# ---------------------------------------------------------------------------
# tdnf
# ---------------------------------------------------------------------------
# refresh_metadata
# Downloads the repository metadata, retrying a transient mirror or DNS failure
# before it is allowed to end the build, and confirming afterwards that the
# repository set is actually usable. That confirmation is not ceremony: tdnf
# returns success after dropping a repository it could not reach, and returns
# success on an image whose every repository is disabled, so without it an
# unpatched image would be declared fully patched.
refresh_metadata() {
  local attempt=1
  local failure=""

  while :; do
    log "refreshing repository metadata (attempt ${attempt}/${PHOTON_PATCH_ATTEMPTS})"
    failure=""

    if ! run_tdnf makecache --refresh; then
      failure="tdnf could not refresh the repository metadata"
    elif repository_was_dropped; then
      failure="tdnf dropped a repository it could not reach"
    elif [[ "$(enabled_repository_count)" -eq 0 ]]; then
      failure="tdnf reports no enabled repository to patch from"
    fi

    if [[ -z "${failure}" ]]; then
      return 0
    fi
    warn "${failure}"

    if (( attempt >= PHOTON_PATCH_ATTEMPTS )); then
      if (( PHOTON_PATCH_STRICT == 1 )); then
        die "could not refresh the Photon repository metadata after ${PHOTON_PATCH_ATTEMPTS} attempts"
      fi
      warn "could not refresh the Photon repository metadata after ${PHOTON_PATCH_ATTEMPTS} attempts - continuing unverified"
      return 1
    fi

    warn "metadata refresh failed; retrying in ${REFRESH_RETRY_DELAY}s"
    sleep "${REFRESH_RETRY_DELAY}"
    attempt=$(( attempt + 1 ))
  done
}

# check_updates
# Reports through the exit status what `tdnf check-update` found:
#   0   updates are pending (tdnf's own convention: an exit status of 100)
#   1   the system is fully up to date
# Any other status is a genuine tdnf error and is fatal, so "nothing to do" and
# "I could not ask" can never be mistaken for each other.
check_updates() {
  local status=0
  run_tdnf check-update --quiet || status=$?

  case "${status}" in
    100)
      return 0
      ;;
    0)
      # tdnf exits 0 both for "nothing is pending" and for "the repository that
      # would have had something has gone", so the answer is only trusted when
      # no repository was dropped along the way.
      if repository_was_dropped; then
        die "tdnf dropped a repository during check-update - cannot prove the image is patched"
      fi
      return 1
      ;;
    *)
      die "tdnf check-update failed (exit ${status}) - cannot prove the image is patched"
      ;;
  esac
}

upgrade_packages() {
  log "upgrading installed packages"
  run_tdnf upgrade --assumeyes
}

distro_sync_packages() {
  log "syncing installed packages against the repositories (distro-sync)"
  run_tdnf distro-sync --assumeyes
}

remove_obsoleted() {
  log "removing the packages the upgrades obsoleted"
  run_tdnf autoremove --assumeyes \
    || warn "tdnf autoremove failed; leaving the obsoleted packages in place"
}

# patch_until_current
# Upgrades and syncs until tdnf reports nothing left to do. Returns non-zero
# when updates are still pending after PHOTON_PATCH_MAX_ROUNDS rounds; the
# caller decides whether that fails the build.
patch_until_current() {
  local round=1
  while :; do
    log "patching round ${round}/${PHOTON_PATCH_MAX_ROUNDS}"
    upgrade_packages
    distro_sync_packages

    if ! check_updates; then
      log "tdnf reports no pending updates"
      return 0
    fi

    if (( round >= PHOTON_PATCH_MAX_ROUNDS )); then
      return 1
    fi

    warn "tdnf still reports pending updates; starting another round"
    round=$(( round + 1 ))
  done
}

# ensure_essential_packages
# Installs the packages whose absence would make the template undeployable. The
# package set the Photon base image ships is what normally guarantees them; this
# only catches the build where something removed one.
#
# The presence check is tdnf's own install rather than `rpm -q`: a minimal
# Photon image does not always carry the rpm command line, and asking for it is
# not worth failing a build over. Installing a package that is already at the
# newest version is a successful no-op, so this stays idempotent.
ensure_essential_packages() {
  local package
  for package in "${ESSENTIAL_PACKAGES[@]}"; do
    log "ensuring ${package} is installed"
    if ! run_tdnf install --assumeyes "${package}"; then
      warn "could not install '${package}' - a clone of this template may not deploy correctly on vSphere"
    fi
  done
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
report_state() {
  local kernels

  log "operating system: VMware Photon OS $(os_version)"
  log "running kernel:   $(uname -r)"

  kernels="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V || true)"
  if [[ -n "${kernels}" ]]; then
    log "installed kernels (what a clone may boot):"
    while IFS= read -r kernel; do
      [[ -n "${kernel}" ]] && log "  ${kernel}"
    done <<< "${kernels}"
  else
    warn "no kernel image found under /boot - the template may not boot"
  fi

  if [[ -f /boot/grub2/grub.cfg ]]; then
    log "boot configuration: /boot/grub2/grub.cfg present"
  else
    warn "/boot/grub2/grub.cfg is missing - the template may not boot"
  fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  parse_arguments "$@"
  validate_settings
  require_root

  # Packer runs this script with -x; decorating PS4 makes the trace readable
  # without turning it off where the caller asked for it.
  if [[ ${TRACE} -eq 1 ]]; then
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
    set -x
  fi

  require_photon

  log "starting update and patch of VMware Photon OS $(os_version), kernel $(uname -r)"

  local metadata_ok=1
  refresh_metadata || metadata_ok=0

  if (( metadata_ok == 1 )); then
    if ! patch_until_current; then
      log "pending updates after ${PHOTON_PATCH_MAX_ROUNDS} rounds:"
      run_tdnf check-update || true

      if (( PHOTON_PATCH_STRICT == 1 )); then
        die "the system still has pending updates after ${PHOTON_PATCH_MAX_ROUNDS} rounds"
      fi
      warn "the system still has pending updates - the image is UNVERIFIED"
    fi

    remove_obsoleted
    ensure_essential_packages

    # The install above can pull a dependency, and removing obsoleted packages
    # can change what is pending, so the final verdict is taken on a fresh
    # metadata read rather than on the state the loop ended in.
    refresh_metadata || metadata_ok=0
  fi

  if (( metadata_ok == 1 )); then
    if check_updates; then
      run_tdnf check-update || true
      if (( PHOTON_PATCH_STRICT == 1 )); then
        die "the system still reports pending updates at the end of the patch run"
      fi
      warn "the system still reports pending updates - the image is UNVERIFIED"
    fi
  fi

  report_state

  if (( metadata_ok == 0 )); then
    warn "the repository metadata could not be refreshed - the image is UNVERIFIED"
  else
    log "the image is fully updated and patched"
  fi

  printf '%s\n' \
    '####################################################' \
    'Updates and patches have completed' \
    '####################################################'
}

main "$@"
