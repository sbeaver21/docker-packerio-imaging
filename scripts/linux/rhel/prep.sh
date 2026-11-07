#!/usr/bin/env bash
#
# prep.sh -- Generalize a RHEL guest before it is captured as a template.
#
# The script removes everything that must not be shared by the VMs cloned from
# the image: the build host's entitlement identity, its SSH host keys, its
# machine-id, its hostname, its package cache, its shell history, its temporary
# files and its logs.
#
# Steps:
#   1. Remove the subscription-manager entitlement identity.
#   2. Remove the legacy persistent network device rule.
#   3. Remove the SSH host keys (sshd regenerates them on first boot).
#   4. Reset the systemd machine-id and the random seed.
#   5. Reset the hostname to "localhost".
#   6. Clear the package manager cache.
#   7. Clear shell history and session artifacts.
#   8. Clear /tmp and /var/tmp.
#   9. Clear the host logs (last, so that nothing this script does re-creates
#      them before the image is captured).
#
# Usage:
#   sudo ./prep.sh [--dry-run] [--help]
#
#   --dry-run   Print every change that would be made, changing nothing.
#               Safe to run on any machine, including non-RHEL ones.
#
# Environment overrides:
#   RESET_MACHINE_ID=0            keep /etc/machine-id (default: 1, reset it)
#   RESET_HOSTNAME=0              keep the build hostname (default: 1, set it
#                                 to "localhost")
#   SUBSCRIPTION_MANAGER_BIN      default: /usr/sbin/subscription-manager
#   ALLOW_NON_ROOT=1              run without elevating via sudo (the caller,
#                                 e.g. a container or CI job, guarantees root)
#
# The script is idempotent: running it twice on the same host is equivalent to
# running it once.
#
# NOTE: the Packer templates under builds/linux/rhel/ run this file as
# `{{.Vars}} sudo -S -E sh -eux '{{.Path}}'`, i.e. bash in POSIX mode with
# errexit and nounset already enabled, and they treat any non-zero exit as a
# failed image build. Keep the script POSIX-mode safe and make every failure
# explicit.
#
# The script deliberately writes no log file: anything written under /var/log
# has to be wiped again before the image is captured, and a build log baked into
# a golden image leaks build metadata into every clone.

set -euo pipefail

readonly PROGRAM_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly LOG_DIR="/var/log"
readonly JOURNAL_DIR="${LOG_DIR}/journal"

# /etc/machine-id is emptied rather than deleted: an empty file makes systemd
# generate a new, unique id on first boot, a missing one leaves the host in a
# degraded state.
readonly MACHINE_ID_FILE="/etc/machine-id"
readonly DBUS_MACHINE_ID_FILE="/var/lib/dbus/machine-id"
readonly RANDOM_SEED_FILE="/var/lib/systemd/random-seed"

readonly HOSTNAME_FILE="/etc/hostname"
readonly MACHINE_INFO_FILE="/etc/machine-info"
readonly GENERIC_HOSTNAME="localhost"

# RHEL 6/7 only; harmless on RHEL 8+ where the file does not exist.
readonly LEGACY_PERSISTENT_NET_RULE="/etc/udev/rules.d/70-persistent-net.rules"

readonly SSH_HOST_KEY_DIR="/etc/ssh"

readonly DNF_CACHE_DIR="/var/cache/dnf"
readonly RHSM_FACTS_DIR="/etc/rhsm/facts"
readonly SUBSCRIPTION_MANAGER_BIN="${SUBSCRIPTION_MANAGER_BIN:-/usr/sbin/subscription-manager}"

readonly -a TEMP_DIRECTORIES=( /tmp /var/tmp )
readonly -a HOME_DIRECTORIES=( /root /home )

# Files left behind by interactive shells and by the tools used during the
# build. Everything listed here either carries build host names (known_hosts)
# or is recreated on first use.
readonly -a SESSION_ARTIFACTS=(
  .bash_history
  .sh_history
  .zsh_history
  .history
  .lesshst
  .viminfo
  .python_history
  .psql_history
  .mysql_history
  .wget-hsts
  known_hosts
)

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
DRY_RUN=0
ALLOW_NON_ROOT="${ALLOW_NON_ROOT:-0}"
RESET_MACHINE_ID="${RESET_MACHINE_ID:-1}"
RESET_HOSTNAME="${RESET_HOSTNAME:-1}"

SCRIPT_PATH=""
TRUNCATED_COUNT=0
REMOVED_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${PROGRAM_NAME}" "$*"
}

warn() {
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

# describe_command <command> [args...]
# Renders a command with shell quoting, so a line copied out of the build log
# behaves the same as the line the script actually ran.
describe_command() {
  local rendered="" argument
  for argument in "$@"; do
    rendered+="$(printf '%q ' "${argument}")"
  done
  printf '%s' "${rendered% }"
}

# run <command> [args...]
# Executes a command that changes the host, logging it first. Under --dry-run
# the command is reported and never executed.
run() {
  if (( DRY_RUN )); then
    log "DRY-RUN would execute: $(describe_command "$@")"
    return 0
  fi
  log "executing: $(describe_command "$@")"
  "$@"
}

# Re-exec under sudo once so the whole script runs at one consistent privilege
# level, instead of escalating with `sudo` per command (and instead of the
# original's `sudo rm -rf ...`, which is redundant inside a root script and
# fails outright when the calling user may not use sudo).
require_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi

  if (( DRY_RUN )); then
    warn "not running as root; a real run would re-execute itself via sudo"
    return 0
  fi

  if [[ "${ALLOW_NON_ROOT}" == "1" ]]; then
    warn "ALLOW_NON_ROOT=1: continuing without root; privileged steps may fail"
    return 0
  fi

  local script_path
  script_path="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
  printf '%s: not running as root, re-executing via sudo\n' "${PROGRAM_NAME}" >&2
  exec sudo -- "${script_path}" "$@"
}

# Commands that must exist for a real run. Anything missing is only a warning
# under --dry-run, so the script can be exercised on a non-RHEL workstation.
require_command() {
  local command_name="$1"

  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi
  if (( DRY_RUN )); then
    warn "required command '${command_name}' not found (tolerated under --dry-run)"
    return 0
  fi
  die "required command not found: ${command_name}"
}

# truncate_file <path>...
# Empties files in place, which preserves their ownership, mode and ACLs. That
# matters for the files the system expects to exist (wtmp, btmp, lastlog), and
# it is why the original `sudo rm -rf /var/log/*` - which also removed
# directories such as /var/log/audit - is gone.
truncate_file() {
  local target
  for target in "$@"; do
    if [[ ! -f "${target}" ]]; then
      continue
    fi

    if (( DRY_RUN )); then
      log "DRY-RUN would empty ${target}"
      continue
    fi

    if truncate -s 0 -- "${target}" 2>/dev/null; then
      TRUNCATED_COUNT=$(( TRUNCATED_COUNT + 1 ))
    else
      warn "could not empty ${target} (immutable or append-only attribute?)"
    fi
  done
}

# remove_path <path>...
remove_path() {
  local target
  for target in "$@"; do
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
      continue
    fi

    if (( DRY_RUN )); then
      log "DRY-RUN would remove ${target}"
      continue
    fi

    rm -rf -- "${target}"
    log "removed ${target}"
    REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
  done
}

# purge_directory <directory>...
# Removes every entry inside a directory while keeping the directory itself.
# Keeping it matters for /var/log/journal: without the directory journald falls
# back to volatile, non-persistent storage.
purge_directory() {
  local target
  for target in "$@"; do
    if [[ ! -d "${target}" ]]; then
      continue
    fi

    if (( DRY_RUN )); then
      log "DRY-RUN would remove the contents of ${target}"
      continue
    fi

    local -a find_args=( "${target}" -mindepth 1 -maxdepth 1 )

    # Never unlink the script that is currently executing: Packer uploads it to
    # /tmp, and bash reads a script incrementally, so whether removing it
    # mid-run is safe depends on how much of the file is still unread.
    if [[ -n "${SCRIPT_PATH}" && -e "${SCRIPT_PATH}" ]]; then
      find_args+=( ! -samefile "${SCRIPT_PATH}" )
    fi

    find "${find_args[@]}" -exec rm -rf -- {} +
    log "emptied ${target}"
  done
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# 1. A golden image must not carry the build host's entitlement identity: every
#    clone would otherwise present the same consumer certificate. Registration
#    is redone on the deployed host by baseline-rhel9.sh / baseline-rhel10.sh.
#
#    Every subscription-manager call is allowed to fail. On a host that was
#    never registered, `unregister` and `clean` exit non-zero, and the original
#    script let that abort the whole image build under the `-e` the templates
#    pass in.
unregister_subscription() {
  log "Step 1/9: removing the subscription-manager entitlement identity"

  if [[ -x "${SUBSCRIPTION_MANAGER_BIN}" ]]; then
    run "${SUBSCRIPTION_MANAGER_BIN}" unregister \
      || warn "subscription-manager unregister failed (host was probably never registered)"
    run "${SUBSCRIPTION_MANAGER_BIN}" clean \
      || warn "subscription-manager clean failed"
  else
    warn "${SUBSCRIPTION_MANAGER_BIN} not found; skipping the subscription scrub"
  fi

  # `clean` removes /etc/pki/consumer and /etc/pki/entitlement but leaves the
  # facts collected from this build host; they are rebuilt on registration.
  purge_directory "${RHSM_FACTS_DIR}"
}

# 2. RHEL 6/7 pinned a NIC name to a MAC address with this udev rule. It does
#    not exist on RHEL 8+, but the check stays so the script also works on older
#    images. (The original removed the same file twice.)
remove_legacy_network_rules() {
  log "Step 2/9: removing the persistent network device rule"
  remove_path "${LEGACY_PERSISTENT_NET_RULE}"
}

# 3. The host key identifies one machine. Clones that share it cannot tell each
#    other apart, and sshd regenerates the keys on first boot when they are
#    missing. (The original removed them, then removed them again.)
remove_ssh_host_keys() {
  log "Step 3/9: removing the SSH host keys"

  local key_file
  local found=0

  for key_file in "${SSH_HOST_KEY_DIR}"/ssh_host_*; do
    if [[ ! -e "${key_file}" ]]; then
      continue
    fi
    found=1
    remove_path "${key_file}"
  done

  if (( ! found )); then
    log "no SSH host keys found in ${SSH_HOST_KEY_DIR}"
  fi
}

# 4. /etc/machine-id is the identity systemd, journald and dbus key their state
#    on; two clones sharing it corrupt each other's journals. It is emptied, not
#    deleted, so systemd generates a fresh one at boot.
#
#    On RHEL 8+ /var/lib/dbus/machine-id is normally a symlink to
#    /etc/machine-id and follows it automatically; the original script recreated
#    that symlink by hand, which is only needed when it is a real file.
reset_machine_id() {
  log "Step 4/9: resetting the systemd machine identity"

  if [[ "${RESET_MACHINE_ID}" != "1" ]]; then
    log "skipping: RESET_MACHINE_ID=0"
    return 0
  fi

  truncate_file "${MACHINE_ID_FILE}"

  if [[ -L "${DBUS_MACHINE_ID_FILE}" ]]; then
    log "${DBUS_MACHINE_ID_FILE} is a symlink to $(readlink -- "${DBUS_MACHINE_ID_FILE}" 2>/dev/null || printf '?'); it follows the file emptied above"
  else
    truncate_file "${DBUS_MACHINE_ID_FILE}"
  fi

  # A random seed captured from the build host is shared entropy for every
  # clone; systemd writes a fresh one on first boot.
  remove_path "${RANDOM_SEED_FILE}"
}

# 5. Every clone would otherwise come up with the build hostname. "localhost" is
#    the placeholder that deployment customisation (vSphere guest
#    customisation) replaces on first boot.
reset_hostname() {
  log "Step 5/9: resetting the hostname"

  if [[ "${RESET_HOSTNAME}" != "1" ]]; then
    log "skipping: RESET_HOSTNAME=0"
    return 0
  fi

  if command -v hostnamectl >/dev/null 2>&1; then
    run hostnamectl set-hostname "${GENERIC_HOSTNAME}" \
      || die "could not reset the hostname; refusing to capture a template that still carries the build hostname"
  else
    warn "hostnamectl not found; writing ${GENERIC_HOSTNAME} to ${HOSTNAME_FILE} instead"
    if (( DRY_RUN )); then
      log "DRY-RUN would write ${GENERIC_HOSTNAME} to ${HOSTNAME_FILE}"
    else
      printf '%s\n' "${GENERIC_HOSTNAME}" > "${HOSTNAME_FILE}"
    fi
  fi

  drop_pretty_hostname
}

# A pretty hostname in /etc/machine-info carries the build name and would
# survive the reset above, because `hostnamectl set-hostname` does not touch it.
drop_pretty_hostname() {
  if [[ ! -f "${MACHINE_INFO_FILE}" ]]; then
    return 0
  fi

  if ! grep -q '^PRETTY_HOSTNAME=' "${MACHINE_INFO_FILE}"; then
    return 0
  fi

  if (( DRY_RUN )); then
    log "DRY-RUN would drop PRETTY_HOSTNAME from ${MACHINE_INFO_FILE}"
    return 0
  fi

  sed -i '/^PRETTY_HOSTNAME=/d' "${MACHINE_INFO_FILE}"
  log "dropped PRETTY_HOSTNAME from ${MACHINE_INFO_FILE}"
}

# 6. `dnf clean all` is the supported way to clear the cache and already covers
#    the original script's separate `rm -rf /var/cache/dnf/*`, which ran before
#    it. The purge afterwards is the fallback for when dnf cannot run.
clean_package_cache() {
  log "Step 6/9: clearing the package manager cache"

  run dnf -y clean all \
    || warn "dnf clean all failed; purging ${DNF_CACHE_DIR} directly instead"

  purge_directory "${DNF_CACHE_DIR}"
}

# 7. Shell history and the small caches left behind by the interactive tools
#    used during the build. The original emptied /root/.bash_history, deleted it
#    again, and called `history -cw`, which does not exist in a non-interactive
#    `sh` and aborts the run under the `-e` the templates pass in.
clear_session_history() {
  log "Step 7/9: clearing shell history and session artifacts"

  # Best-effort: this shell must not record anything, and must not write a
  # history file when it exits.
  unset HISTFILE
  set +o history 2>/dev/null || true

  local -a name_predicate=()
  local artifact_name
  for artifact_name in "${SESSION_ARTIFACTS[@]}"; do
    if (( ${#name_predicate[@]} > 0 )); then
      name_predicate+=( -o )
    fi
    name_predicate+=( -name "${artifact_name}" )
  done

  local artifact_file
  while IFS= read -r -d '' artifact_file; do
    remove_path "${artifact_file}"
  done < <(find "${HOME_DIRECTORIES[@]}" -xdev -maxdepth 3 -type f '(' "${name_predicate[@]}" ')' -print0 2>/dev/null)
}

# 8. The original used `rm -rf /tmp/*`, which leaves dotfiles such as
#    /tmp/.X11-unix behind and, more importantly, can delete the script Packer
#    is running from. purge_directory walks every entry instead - and skips the
#    running script.
purge_temp_directories() {
  log "Step 8/9: clearing the temporary directories"
  purge_directory "${TEMP_DIRECTORIES[@]}"
}

# 9. Logs are cleared last: every earlier step writes something, and anything
#    cleared first is simply written again before the image is captured.
clear_log_files() {
  log "Step 9/9: clearing the host logs"

  # auditd keeps its log open and would write to it again immediately, so it is
  # stopped first. It is deliberately left stopped: the image is shut down right
  # after this script, and its boot-time enablement is untouched.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet auditd; then
    run systemctl stop auditd || warn "could not stop auditd"
  fi

  # The journal is a set of binary files named after the machine-id: truncating
  # them leaves journald with corrupt files, so they are deleted instead. The
  # directory itself stays, otherwise journald falls back to non-persistent
  # storage.
  purge_directory "${JOURNAL_DIR}"

  # Everything else under /var/log is emptied in place, keeping ownership and
  # mode. This replaces the original's `sudo rm -rf /var/log/*`, which also
  # removed directories the system expects to exist, such as /var/log/audit.
  local log_file
  while IFS= read -r -d '' log_file; do
    truncate_file "${log_file}"
  done < <(find "${LOG_DIR}" -xdev -type f -not -path "${JOURNAL_DIR}/*" -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./prep.sh [--dry-run] [--help]

Generalizes a RHEL guest before it is captured as a template: removes the
subscription entitlement identity, the SSH host keys, the machine-id, the
hostname, the package cache, the shell history, the temporary files and the
host logs.

Options:
  --dry-run   Print every change that would be made, changing nothing.
  --help      Show this message.

Environment overrides (see the header of this script): RESET_MACHINE_ID,
RESET_HOSTNAME, SUBSCRIPTION_MANAGER_BIN, ALLOW_NON_ROOT.
EOF
}

parse_arguments() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

check_requirements() {
  require_command truncate
  require_command find
  require_command dnf
}

main() {
  parse_arguments "$@"

  SCRIPT_PATH="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"

  require_root "$@"
  check_requirements

  if (( DRY_RUN )); then
    log "dry-run mode: no changes will be made to $(hostname)"
  else
    log "starting RHEL template preparation on $(hostname)"
  fi

  unregister_subscription
  remove_legacy_network_rules
  remove_ssh_host_keys
  reset_machine_id
  reset_hostname
  clean_package_cache
  clear_session_history
  purge_temp_directories
  clear_log_files

  log "template preparation complete (${TRUNCATED_COUNT} file(s) emptied, ${REMOVED_COUNT} path(s) removed)"
}

# Run only when executed directly, so the script stays sourceable for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
