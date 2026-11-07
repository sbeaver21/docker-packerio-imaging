#!/usr/bin/env bash
#
# baseline-rhel10.sh -- RHEL 10 baseline provisioning.
#
# Steps:
#   1. Trust the Satellite CA bundle and register with subscription-manager.
#   2. Provision SSH access for the `buildops` service account.
#   3. Apply the SELinux / crypto-policy baseline required for the AD realm join.
#   4. Patch the host and install the baseline package set.
#   5. Install the packages needed for the AD realm join.
#
# Usage:
#   sudo ./baseline-rhel10.sh
#
# Environment overrides:
#   SATELLITE_HOST                 default: satellite.example.com
#   SUBSCRIPTION_ORG               default: image-automation
#   SUBSCRIPTION_ACTIVATION_KEY    default: AK_EXAMPLE_Rhel10
#   ALLOW_INSECURE_TLS=1           disable TLS verification for Satellite calls
#
# The script is idempotent and safe to run more than once.
#
# NOTE: the Packer templates run this file as `sh -eux`, i.e. bash in POSIX
# mode with errexit and nounset already on, and they treat any non-zero exit as
# a failed image build. Keep the script POSIX-mode safe and make every failure
# explicit.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly SATELLITE_HOST="${SATELLITE_HOST:-satellite.example.com}"
readonly SATELLITE_CA_RPM_URL="https://${SATELLITE_HOST}/pub/katello-ca-consumer-latest.noarch.rpm"
readonly SATELLITE_PUBKEY_URL="https://${SATELLITE_HOST}:9090/ssh/pubkey"

readonly SUBSCRIPTION_ORG="${SUBSCRIPTION_ORG:-image-automation}"
readonly SUBSCRIPTION_ACTIVATION_KEY="${SUBSCRIPTION_ACTIVATION_KEY:-AK_EXAMPLE_Rhel10}"
readonly SUBSCRIPTION_MANAGER="/usr/sbin/subscription-manager"

readonly SERVICE_USER="buildops"
readonly SERVICE_HOME="${SERVICE_HOME:-/home/${SERVICE_USER}}"

readonly LOG_FILE="/var/log/baseline-rhel10.log"

# The Satellite CA bundle is fetched *before* its CA is trusted, so that single
# request cannot verify TLS. Every other request is verified unless the operator
# explicitly opts out with ALLOW_INSECURE_TLS=1.
readonly ALLOW_INSECURE_TLS="${ALLOW_INSECURE_TLS:-0}"
TLS_OPTS=()
if [[ "${ALLOW_INSECURE_TLS}" == "1" ]]; then
  TLS_OPTS=(--insecure)
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  printf '%s [baseline-rhel10] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG_FILE}"
}

warn() { log "WARNING: $*"; }

die() {
  log "ERROR: $*"
  exit 1
}

# Re-exec under sudo so the whole script runs with one consistent privilege
# level, instead of escalating per-command (and instead of the ineffective
# `sudo su <user>` pattern, which does not change the user of later commands).
ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Not running as root; re-executing via sudo..." >&2
    exec sudo -- "$0" "$@"
  fi
}

# fetch <url> <dest> [extra curl options...]
fetch() {
  local url="$1" dest="$2"
  shift 2
  log "Downloading ${url}"
  curl --fail --location --silent --show-error \
       --retry 3 --retry-delay 5 --connect-timeout 15 \
       "$@" --output "${dest}" "${url}"
}

TMP_DIR=""
cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
install_satellite_ca() {
  local rpm="${TMP_DIR}/katello-ca-consumer-latest.noarch.rpm"

  log "Installing the Satellite CA trust bundle..."
  # This one request must be insecure: it *is* the trust bootstrap. Verify that
  # the payload is a real RPM before it is installed system-wide.
  fetch "${SATELLITE_CA_RPM_URL}" "${rpm}" --insecure

  rpm -qp "${rpm}" >/dev/null 2>&1 \
    || die "Downloaded CA bundle is not a valid RPM: ${rpm}"

  log "CA bundle sha256: $(sha256sum "${rpm}" | cut -d' ' -f1)"
  dnf -y install "${rpm}"
}

configure_service_user_ssh() {
  local ssh_dir="${SERVICE_HOME}/.ssh"
  local authorized_keys="${ssh_dir}/authorized_keys"
  local pubkey="${TMP_DIR}/buildops.pubkey"

  id "${SERVICE_USER}" >/dev/null 2>&1 \
    || die "Service user '${SERVICE_USER}' does not exist"

  log "Provisioning SSH access for ${SERVICE_USER}..."
  fetch "${SATELLITE_PUBKEY_URL}" "${pubkey}" "${TLS_OPTS[@]}"

  install -d -m 0700 -o "${SERVICE_USER}" "${ssh_dir}"
  touch "${authorized_keys}"
  chown "${SERVICE_USER}" "${authorized_keys}"
  chmod 0600 "${authorized_keys}"

  # Add only keys that are not already present, so re-runs stay idempotent.
  local key added=0
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    if ! grep -qxF -- "${key}" "${authorized_keys}"; then
      printf '%s\n' "${key}" >> "${authorized_keys}"
      added=$((added + 1))
    fi
  done < "${pubkey}"

  log "Installed ${added} new authorized key(s) for ${SERVICE_USER}"
}

register_subscription() {
  log "Registering with subscription-manager..."
  "${SUBSCRIPTION_MANAGER}" register \
    --org="${SUBSCRIPTION_ORG}" \
    --activationkey="${SUBSCRIPTION_ACTIVATION_KEY}" \
    --force

  "${SUBSCRIPTION_MANAGER}" status
  "${SUBSCRIPTION_MANAGER}" refresh
  "${SUBSCRIPTION_MANAGER}" repos --list
  "${SUBSCRIPTION_MANAGER}" repos --enable "*"
}

apply_security_baseline() {
  local current_mode
  current_mode="$(getenforce)"

  if [[ "${current_mode}" == "Enforcing" ]]; then
    warn "Setting SELinux to permissive (was ${current_mode}); this reduces host isolation."
    warn "The persistent setting in /etc/selinux/config is intentionally left unchanged."
    setenforce 0
  else
    log "SELinux already in '${current_mode}' mode."
  fi

  log "Enabling the AD-SUPPORT crypto policy (required for the AD realm join)..."
  update-crypto-policies --set DEFAULT:AD-SUPPORT
}

update_system() {
  log "Cleaning the package cache and upgrading the system..."
  dnf -y clean packages
  dnf -y upgrade
}

install_baseline_packages() {
  log "Installing baseline packages..."
  dnf -y install \
    open-vm-tools \
    chrony \
    yum-utils
}

prepare_ad_realm_join() {
  log "Installing packages required for the AD realm join..."
  dnf -y install \
    samba-common-tools \
    realmd \
    oddjob \
    oddjob-mkhomedir \
    sssd \
    adcli \
    krb5-workstation
}

main() {
  ensure_root "$@"

  : > "${LOG_FILE}"
  log "Starting RHEL 10 baseline provisioning on $(hostname)"

  TMP_DIR="$(mktemp -d)"
  trap cleanup EXIT

  install_satellite_ca
  configure_service_user_ssh
  register_subscription
  apply_security_baseline
  update_system
  install_baseline_packages
  prepare_ad_realm_join

  log "Baseline provisioning complete."
}

# Run only when executed directly, so the script remains sourceable for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
