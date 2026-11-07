#!/usr/bin/env bash
#
# baseline-rhel9.sh -- RHEL 9 baseline provisioning.
#
# Steps:
#   1. Trust the Satellite CA bundle.
#   2. Provision SSH access for the `buildops` service account.
#   3. Register the host with subscription-manager.
#   4. Apply the SELinux / crypto-policy baseline required for the AD realm join.
#   5. Patch the host.
#   6. Install the baseline package set.
#   7. Install the packages needed for the AD realm join.
#
# Usage:
#   sudo ./baseline-rhel9.sh [--dry-run] [--help]
#
#   --dry-run   Print every command that would run without changing the host.
#               Safe to run on any machine, including non-RHEL ones.
#
# Environment overrides:
#   SATELLITE_HOST                default: satellite.example.com
#   SUBSCRIPTION_ORG              default: image-automation
#   SUBSCRIPTION_ACTIVATION_KEY   default: AK_EXAMPLE_Rhel9
#   SERVICE_USER / SERVICE_HOME   default: buildops / /home/buildops
#   LOG_FILE                      default: /var/log/baseline-rhel9.log
#   ALLOW_INSECURE_TLS=1          disable TLS verification for all downloads
#   ENABLE_ALL_REPOS=0            do not run `repos --enable "*"`
#   SELINUX_PERMISSIVE=0          leave SELinux enforcement untouched
#   ALLOW_NON_ROOT=1              run without elevating via sudo (the caller,
#                                 e.g. a container or CI job, guarantees root)
#
# The script is idempotent: every step can be re-run on an already-provisioned
# host without duplicating keys, repositories, or firewall rules.
#
# NOTE: the Packer templates under builds/linux/rhel/ run this file as
# `sh -eux`, i.e. bash in POSIX mode with errexit and nounset already on, and
# they treat any non-zero exit as a failed image build. Keep the script
# POSIX-mode safe and make every failure explicit.

set -euo pipefail

readonly PROGRAM_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly SATELLITE_HOST="${SATELLITE_HOST:-satellite.example.com}"
readonly SATELLITE_CA_RPM_URL="https://${SATELLITE_HOST}/pub/katello-ca-consumer-latest.noarch.rpm"
readonly SATELLITE_SSH_PUBKEY_URL="https://${SATELLITE_HOST}:9090/ssh/pubkey"

readonly SUBSCRIPTION_ORG="${SUBSCRIPTION_ORG:-image-automation}"
readonly SUBSCRIPTION_ACTIVATION_KEY="${SUBSCRIPTION_ACTIVATION_KEY:-AK_EXAMPLE_Rhel9}"
readonly SUBSCRIPTION_MANAGER_BIN="${SUBSCRIPTION_MANAGER_BIN:-/usr/sbin/subscription-manager}"

readonly SERVICE_USER="${SERVICE_USER:-buildops}"
readonly SERVICE_HOME="${SERVICE_HOME:-/home/${SERVICE_USER}}"

readonly -a BASELINE_PACKAGES=(
  open-vm-tools
  chrony
  yum-utils
  chkconfig
)

readonly -a REALM_JOIN_PACKAGES=(
  samba-common-tools
  realmd
  oddjob
  oddjob-mkhomedir
  sssd
  adcli
  krb5-workstation
)

# RHEL 9 still needs the legacy AD crypto policy for the realm join; RHEL 10
# uses DEFAULT:AD-SUPPORT instead (see baseline-rhel10.sh).
readonly CRYPTO_POLICY="DEFAULT:AD-SUPPORT-LEGACY"

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
DRY_RUN=0
ALLOW_INSECURE_TLS="${ALLOW_INSECURE_TLS:-0}"
ENABLE_ALL_REPOS="${ENABLE_ALL_REPOS:-1}"
SELINUX_PERMISSIVE="${SELINUX_PERMISSIVE:-1}"
ALLOW_NON_ROOT="${ALLOW_NON_ROOT:-0}"

LOG_FILE="${LOG_FILE:-}"
LOG_TO_FILE=0
TMP_DIR=""

# --insecure is added to every curl invocation only when the operator opts in.
# The CA-bootstrap request always passes it explicitly and is the one place the
# flag is genuinely required.
TLS_OPTS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [${PROGRAM_NAME}] $*"
  printf '%s\n' "${line}"
  if (( LOG_TO_FILE )); then
    printf '%s\n' "${line}" >> "${LOG_FILE}"
  fi
}

warn() {
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

# describe_command <command> [args...]
# Renders a command with shell quoting, so a line copied out of the log behaves
# the same as the line the script actually ran.
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

# Re-exec the whole script under sudo once, so every command runs at one
# consistent privilege level instead of escalating per command. Callers that
# already guarantee root and cannot use sudo (containers, CI jobs) set
# ALLOW_NON_ROOT=1.
require_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${ALLOW_NON_ROOT}" == "1" ]]; then
    warn "ALLOW_NON_ROOT=1: continuing without root; privileged steps may fail"
    return 0
  fi

  local script_path
  script_path="$(readlink -f "$0")"
  echo "${PROGRAM_NAME}: not running as root, re-executing via sudo" >&2
  exec sudo -- "${script_path}" "$@"
}

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

require_service_user() {
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    return 0
  fi
  if (( DRY_RUN )); then
    warn "service user '${SERVICE_USER}' does not exist (tolerated under --dry-run)"
    return 0
  fi
  die "service user '${SERVICE_USER}' does not exist; create it before provisioning"
}

# fetch <url> <destination> [extra curl options...]
fetch() {
  local url="$1"
  local destination="$2"
  shift 2

  log "downloading ${url}"

  if (( DRY_RUN )); then
    log "DRY-RUN would execute: curl ... ${url} --output ${destination}"
    : > "${destination}"
    return 0
  fi

  curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 5 --connect-timeout 15 \
    "$@" --output "${destination}" "${url}"
}

init_tls_options() {
  TLS_OPTS=()
  if [[ "${ALLOW_INSECURE_TLS}" == "1" ]]; then
    warn "ALLOW_INSECURE_TLS=1: TLS certificate verification is disabled for all downloads"
    TLS_OPTS=(--insecure)
  fi
}

init_logging() {
  if [[ -z "${LOG_FILE}" ]]; then
    if (( DRY_RUN )); then
      LOG_FILE="${TMPDIR:-/tmp}/baseline-rhel9.dry-run.log"
    else
      LOG_FILE="/var/log/baseline-rhel9.log"
    fi
  fi

  if : > "${LOG_FILE}" 2>/dev/null; then
    LOG_TO_FILE=1
  else
    LOG_TO_FILE=0
    warn "cannot write to ${LOG_FILE}; logging to stdout only"
  fi
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# 1. The Satellite CA bundle must be trusted before any other Satellite URL can
#    be verified, so this single request is deliberately insecure. The payload
#    is validated as a real RPM before it is handed to the package manager.
install_satellite_ca() {
  local ca_rpm="${TMP_DIR}/katello-ca-consumer-latest.noarch.rpm"

  log "Step 1/7: trusting the Satellite CA bundle"
  fetch "${SATELLITE_CA_RPM_URL}" "${ca_rpm}" --insecure

  if (( DRY_RUN )); then
    log "DRY-RUN would verify that ${ca_rpm} is an RPM and install it"
  else
    rpm -qp "${ca_rpm}" >/dev/null 2>&1 \
      || die "downloaded CA bundle is not a valid RPM: ${ca_rpm}"
    log "CA bundle sha256: $(sha256sum "${ca_rpm}" | cut -d' ' -f1)"
  fi

  run dnf -y install "${ca_rpm}"
}

# Reconciles the service account's authorized_keys instead of appending
# blindly, so re-running the script does not duplicate keys.
reconcile_authorized_keys() {
  local source_file="$1"
  local authorized_keys="$2"
  local key
  local added=0

  while IFS= read -r key || [[ -n "${key}" ]]; do
    if [[ -z "${key}" ]]; then
      continue
    fi
    if grep -qxF -- "${key}" "${authorized_keys}"; then
      continue
    fi
    printf '%s\n' "${key}" >> "${authorized_keys}"
    added=$(( added + 1 ))
  done < "${source_file}"

  log "installed ${added} new authorized key(s) for ${SERVICE_USER}"
}

# 2. The original script created /home/buildops/.ssh with a bare mkdir (which
#    fails on a second run) and left authorized_keys owned by root.
configure_service_user_ssh() {
  local ssh_dir="${SERVICE_HOME}/.ssh"
  local authorized_keys="${ssh_dir}/authorized_keys"
  local pubkey_file="${TMP_DIR}/buildops.pubkey"

  log "Step 2/7: provisioning SSH access for ${SERVICE_USER}"
  require_service_user
  fetch "${SATELLITE_SSH_PUBKEY_URL}" "${pubkey_file}" "${TLS_OPTS[@]}"

  run install -d -m 0700 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${ssh_dir}"

  if (( DRY_RUN )); then
    log "DRY-RUN would reconcile ${authorized_keys} from ${pubkey_file}"
    return 0
  fi

  touch "${authorized_keys}"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${authorized_keys}"
  chmod 0600 "${authorized_keys}"
  reconcile_authorized_keys "${pubkey_file}" "${authorized_keys}"
}

# 3. `subscription-manager status` is non-zero for unregistered or partially
#    subscribed hosts, so its exit code must not abort the run.
register_subscription() {
  log "Step 3/7: registering with subscription-manager"
  require_command "${SUBSCRIPTION_MANAGER_BIN}"

  run "${SUBSCRIPTION_MANAGER_BIN}" register \
    --org="${SUBSCRIPTION_ORG}" \
    --activationkey="${SUBSCRIPTION_ACTIVATION_KEY}" \
    --force

  run "${SUBSCRIPTION_MANAGER_BIN}" status || warn "subscription-manager reports a non-healthy status; review before continuing"
  run "${SUBSCRIPTION_MANAGER_BIN}" refresh

  if [[ "${ENABLE_ALL_REPOS}" == "1" ]]; then
    warn "enabling every repository offered by the Satellite; set ENABLE_ALL_REPOS=0 to keep the default set"
    run "${SUBSCRIPTION_MANAGER_BIN}" repos --enable "*"
  else
    log "skipping 'repos --enable \"*\"' (ENABLE_ALL_REPOS=0)"
  fi

  run "${SUBSCRIPTION_MANAGER_BIN}" repos --list
}

# 4. SELinux is only relaxed, never disabled persistently, and the change is
#    announced loudly because it lowers host isolation.
apply_security_baseline() {
  log "Step 4/7: applying the SELinux and crypto-policy baseline"

  if [[ "${SELINUX_PERMISSIVE}" != "1" ]]; then
    log "SELinux enforcement left unchanged (SELINUX_PERMISSIVE=0)"
  elif (( DRY_RUN )); then
    log "DRY-RUN would set SELinux to permissive if it is currently Enforcing"
  else
    local current_mode
    current_mode="$(getenforce)"

    if [[ "${current_mode}" == "Enforcing" ]]; then
      warn "setting SELinux to permissive (was ${current_mode}); host isolation is reduced"
      warn "the persistent setting in /etc/selinux/config is intentionally left unchanged"
      setenforce 0
    else
      log "SELinux is already in '${current_mode}' mode"
    fi
  fi

  log "enabling the ${CRYPTO_POLICY} crypto policy (required by the RHEL 9 AD realm join)"
  run update-crypto-policies --set "${CRYPTO_POLICY}"
}

# 5. `yum update` and `yum upgrade` are the same transaction on RHEL 9 (yum is
#    dnf), so the original pair of calls is collapsed into one.
update_system() {
  log "Step 5/7: cleaning the package cache and patching the host"
  run dnf -y clean packages
  run dnf -y upgrade
}

# 6. One transaction instead of one call per package.
install_baseline_packages() {
  log "Step 6/7: installing the baseline package set"
  run dnf -y install "${BASELINE_PACKAGES[@]}"
}

# 7. Kept as a separate step so the realm join in the caller's playbook can
#    depend on this script having completed successfully.
prepare_ad_realm_join() {
  log "Step 7/7: installing the AD realm-join package set"
  run dnf -y install "${REALM_JOIN_PACKAGES[@]}"
}

# A patched kernel or firmware only takes effect after a reboot, and yum-utils
# (installed above) provides needs-restarting to detect that state. Without
# this, hosts are left half-patched with no signal to the operator.
report_reboot_requirement() {
  if (( DRY_RUN )); then
    log "DRY-RUN would check whether a reboot is required"
    return 0
  fi

  if ! command -v needs-restarting >/dev/null 2>&1; then
    return 0
  fi

  if needs-restarting -r >/dev/null 2>&1; then
    log "no reboot required"
  else
    warn "a reboot is required to finish applying the updates"
  fi
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./baseline-rhel9.sh [--dry-run] [--help]

Provisions a RHEL 9 host against the Satellite: trusts the Satellite CA,
registers the subscription, provisions the buildops SSH account, and applies
the baseline package and crypto policy.

Options:
  --dry-run   Print every command that would run, changing nothing.
  --help      Show this message.

Environment overrides (see the header of this script): SATELLITE_HOST,
SUBSCRIPTION_ORG, SUBSCRIPTION_ACTIVATION_KEY, SERVICE_USER, SERVICE_HOME,
LOG_FILE, ALLOW_INSECURE_TLS, ENABLE_ALL_REPOS, SELINUX_PERMISSIVE,
ALLOW_NON_ROOT.
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

# Commands that must exist for the real run. Anything missing is only a warning
# under --dry-run so the script can be exercised on a non-RHEL workstation.
check_requirements() {
  require_command curl
  require_command dnf
  require_command rpm
  require_command update-crypto-policies
}

main() {
  parse_arguments "$@"
  init_tls_options
  init_logging

  log "starting RHEL 9 baseline provisioning on $(hostname)"

  if (( DRY_RUN )); then
    # A dry run changes nothing, so it needs no privileges and can be
    # exercised on any workstation.
    log "dry-run mode: no changes will be made to this host"
    if [[ "${EUID}" -ne 0 ]]; then
      warn "not running as root; a real run would re-execute itself via sudo"
    fi
  else
    require_root "$@"
  fi

  check_requirements

  TMP_DIR="$(mktemp -d)"
  trap cleanup EXIT

  install_satellite_ca
  configure_service_user_ssh
  register_subscription
  apply_security_baseline
  update_system
  install_baseline_packages
  prepare_ad_realm_join
  report_reboot_requirement

  log "baseline provisioning complete"
}

# Run only when executed directly, so the script stays sourceable for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
