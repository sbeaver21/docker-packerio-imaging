#!/usr/bin/env bash
#
# cleanup.sh -- Shrink a RHEL guest and leave it fit to be cloned.
#
# This runs after prep.sh. prep.sh removes the identity that must not be shared
# by the VMs cloned from the image (the subscription entitlement, the SSH host
# keys, the machine-id, the hostname, the package cache, the shell history, the
# temporary files and the logs); this script shrinks what is left and turns off
# a few things the fixture does not want.
#
# Steps:
#   1. Reset the systemd machine identity (machine-id, dbus machine-id, random
#      seed). Repeated from prep.sh so this script is also safe on its own; the
#      reset is idempotent.
#   2. Clear /tmp and /var/tmp, keeping the directories themselves.
#   3. Disable IPv6: kernel command line, sysctl drop-in, GRUB configuration.
#   4. Clear the login accounting files (wtmp, btmp, lastlog, faillog).
#   5. Clear the host logs, the journal included.
#   6. Zero the swap space and re-create it with its original UUID, so the
#      /etc/fstab entries keep resolving. Swap stays off until the clone boots.
#   7. Fill the free space of the root filesystem - and of a separate /boot
#      mount - with zeros and delete the filler, so the datastore stores a
#      thinner image. This is the last step that writes anything.
#   8. Report the disk usage and the network configuration.
#
# Usage:
#   sudo ./cleanup.sh [--dry-run] [--help]
#
#   --dry-run   Print every change that would be made, changing nothing.
#               Safe to run on any machine, including non-RHEL ones.
#
# Environment overrides:
#   ZERO_SWAP=0          keep the swap space untouched (default: 1, zero it)
#   ZERO_FREE_SPACE=0    do not fill the free space with zeros (default: 1)
#   RESET_MACHINE_ID=0   keep /etc/machine-id (default: 1, reset it)
#   ALLOW_NON_ROOT=1     run without elevating via sudo (the caller, e.g. a
#                        container or CI job, guarantees root)
#   SWAP_DEVICES         space separated list of swap devices to clear instead
#                        of asking blkid (default: autodetect)
#
# The script is idempotent: running it twice on the same host is equivalent to
# running it once.
#
# NOTE: the Packer templates under builds/linux/rhel/ run this file as
# `{{.Vars}} sudo -S -E sh -eux '{{.Path}}'`, i.e. bash in POSIX mode with
# errexit, nounset and xtrace already enabled, and they treat any non-zero exit
# as a failed image build. Keep the script POSIX-mode safe and make every
# failure explicit. (The templates upload it to /tmp, so the purge in step 2
# deliberately spares the copy that bash is still reading - see purge_directory.
# The price of that protection is that this one file survives in /tmp; deleting
# it from here would mean unlinking the script bash has not finished reading.)
#
# Unlike prep.sh this script does report what it did, on stdout: the Packer
# build log is the only record of the state the image was captured in. It
# writes no log file - anything written under /var/log has to be wiped again in
# step 5, and a build log baked into a golden image leaks build metadata into
# every clone.
#
# Modified from boxcutter (https://github.com/boxcutter): the swap whiteout, the
# free-space zeroing and the login accounting wipe follow its cleanup.sh. What
# changed, and why:
#   - The log wipe emptied every file under /var/log with a shell redirect -
#     journald's binary journal files included, which leaves journald with
#     corrupt files - and a redirect that failed aborted the whole build under
#     errexit. It also relied on echo understanding -n/-e, which is true for
#     bash - and /bin/sh is bash on RHEL - but not for dash, which would have
#     written the string "-ne" into every log file.
#   - `rm -rf /tmp/*` left dotfiles behind and unlinked the script Packer is
#     running from, which survives only because the shell keeps the file
#     descriptor of a script it is reading open.
#   - `set -x` is gone: the templates already pass -x, and xtrace cannot be
#     turned off from inside the script.
#   - A step that legitimately fails on some images - a swap device that is
#     already off, a command the image does not have - no longer aborts the
#     image build, and the swap whiteout is bounded so that a swap *file*
#     cannot be grown until its filesystem is full.
#   - The free space of a separate /boot mount is whiteouted too (the original
#     left that code commented out), and the GRUB configuration is regenerated
#     at the path the UEFI guests these templates build actually read.

set -euo pipefail

PROGRAM_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly PROGRAM_NAME

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

readonly -a TEMP_DIRECTORIES=( /tmp /var/tmp )

# Records of who logged in to the build host (and failed to). Emptied in place,
# not deleted: `last` and `lastlog` expect the files to exist, and emptying
# keeps their ownership, mode and ACLs.
readonly -a LOGIN_RECORD_FILES=(
  "${LOG_DIR}/wtmp"
  "${LOG_DIR}/btmp"
  "${LOG_DIR}/lastlog"
  "${LOG_DIR}/faillog"
)

readonly IPV6_KERNEL_ARGUMENT="ipv6.disable=1"
readonly IPV6_SYSCTL_FILE="/etc/sysctl.d/60-disable_ipv6.conf"

readonly BOOT_DIR="/boot"
readonly GRUB_BIOS_CONFIG="${BOOT_DIR}/grub2/grub.cfg"
readonly GRUB_EFI_CONFIG="${BOOT_DIR}/efi/EFI/redhat/grub.cfg"

readonly FREE_SPACE_FILLER="/EMPTY"
readonly BOOT_FILLER="${BOOT_DIR}/whitespace"
readonly ZERO_BLOCK_SIZE="1M"

# The same block size in bytes, for the arithmetic that has to bound a write to
# the size of a swap file.
readonly MEBIBYTE=1048576

# Filling a filesystem that has no room left to give is pointless work: below
# this much free space (in 1K blocks) the fill is skipped.
readonly FILL_MINIMUM_KIB=16384

readonly -a REQUIRED_COMMANDS=( awk dd df find stat sync truncate )

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
DRY_RUN=0
ALLOW_NON_ROOT="${ALLOW_NON_ROOT:-0}"
ZERO_SWAP="${ZERO_SWAP:-1}"
ZERO_FREE_SPACE="${ZERO_FREE_SPACE:-1}"
RESET_MACHINE_ID="${RESET_MACHINE_ID:-1}"
SWAP_DEVICES="${SWAP_DEVICES:-}"

SCRIPT_PATH=""
DISK_USAGE_BEFORE_CLEANUP=""
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

# log_block <text>
# Logs a block of text (the output of df, for instance) one line at a time, so
# every line carries the same prefix as the rest of the log.
log_block() {
  local text="$1"
  local line

  while IFS= read -r line; do
    if [[ -n "${line}" ]]; then
      log "  ${line}"
    fi
  done <<< "${text}"
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
# it is why the original's `find /var/log -type f | while read f; do echo -ne ''
# > "${f}"; done` is gone: it emptied journald's binary files as well, a
# redirect that fails aborts the build, and `echo -ne` is not portable - dash
# writes the string "-ne" instead of emptying the file.
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

# is_mountpoint <path>
# True when the path is a mount point of its own, read straight out of the
# kernel's mount table. Used to decide whether a separate /boot needs its free
# space whiteouted as well: when /boot is a plain directory on the root
# filesystem, the root fill already covers that space.
is_mountpoint() {
  local target="$1"
  awk -v target="${target}" '$2 == target { found = 1 } END { exit !found }' /proc/mounts
}

# is_swap_device <device>
# True only when blkid recognises a swap signature on the device. The whiteout
# below destroys whatever a device holds, so nothing is zeroed on a guess.
is_swap_device() {
  local device="$1"

  if ! command -v blkid >/dev/null 2>&1; then
    return 1
  fi
  [[ "$(blkid -o value -s TYPE -- "${device}" 2>/dev/null || true)" == "swap" ]]
}

# is_active_swap <device>
# True when the kernel currently uses the device as swap. /proc/swaps lists the
# path the kernel knows the device by, which is not always the path blkid
# prints (an LVM alias or a by-uuid link, for instance), so the full path, its
# resolved target and its basename are all accepted.
is_active_swap() {
  local device="$1"
  local device_name
  local resolved_device

  device_name="$(basename -- "${device}")"
  resolved_device="$(readlink -f -- "${device}" 2>/dev/null || printf '%s' "${device}")"

  awk -v device="${device}" -v name="${device_name}" -v resolved="${resolved_device}" \
    'NR > 1 && ($1 == device || $1 == name || $1 == resolved) { found = 1 } END { exit !found }' \
    /proc/swaps
}

# detect_swap_devices
# Prints the path of every block device blkid reports as swap, one per line.
# The original asked blkid for the UUID and then looked the device up under
# /dev/disk/by-uuid; when udev has not populated that directory - a freshly
# installed guest that has not completed a boot, for instance - the lookup
# produced an empty string, so the script either zeroed nothing or ran dd with
# an empty target.
detect_swap_devices() {
  if ! command -v blkid >/dev/null 2>&1; then
    return 0
  fi
  blkid -o device -t TYPE=swap 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

# 1. /etc/machine-id is the identity systemd, journald and dbus key their state
#    on; two clones sharing it corrupt each other's journals. It is emptied, not
#    deleted, so systemd generates a fresh one at boot.
#
#    This repeats prep.sh's step 4 on purpose: cleanup.sh is the last script in
#    the provisioner list and must leave a generalized host even if it is ever
#    run without prep.sh. The reset is idempotent, so the repetition is free.
reset_machine_identity() {
  log "Step 1/8: resetting the systemd machine identity"

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

# 2. The original's `rm -rf /tmp/*` left dotfiles behind and could delete the
#    script Packer is running from. purge_directory walks every entry instead,
#    and spares the script that is still being read.
purge_temp_directories() {
  log "Step 2/8: clearing the temporary directories"
  purge_directory "${TEMP_DIRECTORIES[@]}"
}

# 3. The kernel argument turns IPv6 off before the network comes up; the sysctl
#    drop-in turns it off on a running system, and on a host whose boot loader
#    is not managed by grubby (a container, for instance). Both are wanted: the
#    drop-in applies the change, the kernel argument keeps it applied.
disable_ipv6() {
  log "Step 3/8: disabling IPv6"

  local kernel_argument_added=0

  if command -v grubby >/dev/null 2>&1; then
    if grubby --info=ALL 2>/dev/null | grep -qF -- "${IPV6_KERNEL_ARGUMENT}"; then
      log "the kernel command line already carries ${IPV6_KERNEL_ARGUMENT}"
    elif run grubby --update-kernel=ALL --args="${IPV6_KERNEL_ARGUMENT}"; then
      kernel_argument_added=1
    else
      warn "grubby could not add ${IPV6_KERNEL_ARGUMENT} to the kernel command line"
    fi
  else
    warn "grubby not found; IPv6 can only be disabled at runtime by ${IPV6_SYSCTL_FILE}"
  fi

  write_ipv6_sysctl_configuration

  if command -v sysctl >/dev/null 2>&1; then
    run sysctl -p "${IPV6_SYSCTL_FILE}" \
      || warn "could not apply ${IPV6_SYSCTL_FILE} to the running kernel"
  else
    warn "sysctl not found; ${IPV6_SYSCTL_FILE} takes effect on the next boot"
  fi

  # Only a change to the kernel command line makes the GRUB configuration stale,
  # and regenerating it is the slowest step here, so it is skipped when the
  # argument was already present - which also keeps a second run cheap.
  if (( kernel_argument_added )); then
    regenerate_grub_configuration
  fi
}

# write_ipv6_sysctl_configuration
# Writes the drop-in in one go rather than appending line by line, so a second
# run leaves the same two lines behind instead of growing the file. The
# directory is created when it is missing - a minimal image does not have
# /etc/sysctl.d - and a write that fails is a warning rather than a failed
# build: the kernel argument added above already disables IPv6 at boot.
write_ipv6_sysctl_configuration() {
  local content
  local sysctl_dir
  content="$(printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n')"
  sysctl_dir="$(dirname -- "${IPV6_SYSCTL_FILE}")"

  if (( DRY_RUN )); then
    log "DRY-RUN would write ${IPV6_SYSCTL_FILE}:"
    log_block "${content}"
    return 0
  fi

  if [[ ! -d "${sysctl_dir}" ]]; then
    if ! run mkdir -p -- "${sysctl_dir}"; then
      warn "could not create ${sysctl_dir}; IPv6 is only disabled through the kernel command line"
      return 0
    fi
  fi

  if printf '%s\n' "${content}" > "${IPV6_SYSCTL_FILE}"; then
    log "wrote ${IPV6_SYSCTL_FILE} (IPv6 off on every current and future interface)"
  else
    warn "could not write ${IPV6_SYSCTL_FILE}; IPv6 is only disabled through the kernel command line"
  fi
}

# regenerate_grub_configuration
# Rewrites the GRUB configuration at the path the firmware actually reads. The
# original always wrote /boot/grub2/grub.cfg, which a UEFI guest does not read:
# there the configuration lives in the EFI system partition. grubby has already
# updated the Boot Loader Specification entries that RHEL 8+ boots from;
# regenerating the configuration keeps the two consistent.
regenerate_grub_configuration() {
  if ! command -v grub2-mkconfig >/dev/null 2>&1; then
    warn "grub2-mkconfig not found; relying on the boot entries grubby rewrote"
    return 0
  fi

  local grub_config=""
  if [[ -d /sys/firmware/efi && -f "${GRUB_EFI_CONFIG}" ]]; then
    grub_config="${GRUB_EFI_CONFIG}"
  elif [[ -f "${GRUB_BIOS_CONFIG}" ]]; then
    grub_config="${GRUB_BIOS_CONFIG}"
  fi

  if [[ -z "${grub_config}" ]]; then
    warn "neither ${GRUB_EFI_CONFIG} nor ${GRUB_BIOS_CONFIG} exists; skipping the regeneration"
    return 0
  fi

  log "regenerating ${grub_config}"
  run grub2-mkconfig -o "${grub_config}" || warn "could not regenerate ${grub_config}"
}

# 4. wtmp, btmp, lastlog and faillog record who logged in to the build host and
#    who failed to; a clone must not start with them. They are emptied, not
#    deleted: `last` and `lastlog` expect the files to exist, and emptying keeps
#    their ownership and mode. (The original created them with a shell redirect
#    when they were missing, which would hand `last` a file owned by the wrong
#    user and mode.)
clear_login_records() {
  log "Step 4/8: clearing the login records"

  local record_file
  for record_file in "${LOGIN_RECORD_FILES[@]}"; do
    if [[ -e "${record_file}" ]]; then
      truncate_file "${record_file}"
    else
      log "${record_file} is not present; nothing to clear"
    fi
  done
}

# 5. Logs are cleared after every other step that can write one - the IPv6 and
#    swap steps above, for instance - so that nothing they emit survives into
#    the image.
clear_log_files() {
  log "Step 5/8: clearing the host logs"

  # auditd holds its log open and would write to it again straight away, so it
  # is stopped first. It is left stopped on purpose: the image is shut down
  # right after this script, and its boot-time enablement is untouched.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet auditd; then
    run systemctl stop auditd || warn "could not stop auditd"
  fi

  # The journal is a set of binary files named after the machine-id: emptying
  # them leaves journald with corrupt files (which is what the original did), so
  # they are deleted instead. The directory itself stays, otherwise journald
  # falls back to non-persistent storage.
  purge_directory "${JOURNAL_DIR}"

  # Everything else under /var/log is emptied in place, keeping ownership and
  # mode. This replaces the original's `sudo rm -rf /var/log/*`, which also
  # removed directories the system expects to exist, such as /var/log/audit.
  local log_file
  while IFS= read -r -d '' log_file; do
    truncate_file "${log_file}"
  done < <(find "${LOG_DIR}" -xdev -type f -not -path "${JOURNAL_DIR}/*" -print0 2>/dev/null)
}

# 6. Swap is whiteouted so the datastore does not store the gigabytes of stale
#    pages the build host left in it, then re-created with the same UUID so the
#    /etc/fstab entries keep resolving. Swap is left off until the clone boots,
#    which is also why mkswap's fresh signature - without any resume data - is
#    what a cloned template should carry.
clear_swap() {
  log "Step 6/8: clearing the swap space"

  if [[ "${ZERO_SWAP}" != "1" ]]; then
    log "skipping: ZERO_SWAP=0"
    return 0
  fi

  local -a swap_devices=()
  local device

  # Word splitting is intended: SWAP_DEVICES is a space separated list, and the
  # entries are device paths.
  for device in ${SWAP_DEVICES}; do
    swap_devices+=( "${device}" )
  done

  if (( ${#swap_devices[@]} == 0 )); then
    local detected
    while IFS= read -r detected; do
      if [[ -n "${detected}" ]]; then
        swap_devices+=( "${detected}" )
      fi
    done < <(detect_swap_devices)
  fi

  if (( ${#swap_devices[@]} == 0 )); then
    log "no swap device found; nothing to clear"
    return 0
  fi

  for device in "${swap_devices[@]}"; do
    clear_swap_device "${device}"
  done
}

# clear_swap_device <device>
# Zeroes one swap device and re-creates its swap signature. The device is
# checked before it is touched: the original resolved /dev/disk/by-uuid/<uuid>
# and handed the result straight to swapoff, dd and mkswap without checking what
# it was, and its `blkid -l` only ever considered the last swap device.
clear_swap_device() {
  local device="$1"
  local swap_uuid=""

  if ! is_swap_device "${device}"; then
    warn "refusing to zero ${device}: it does not carry a swap signature"
    return 0
  fi

  swap_uuid="$(blkid -o value -s UUID -- "${device}" 2>/dev/null || true)"

  if (( DRY_RUN )); then
    log "DRY-RUN would turn ${device} off, zero it and re-create its swap signature with UUID ${swap_uuid:-<a new one>}"
    return 0
  fi

  if is_active_swap "${device}"; then
    log "turning the swap on ${device} off (it stays off until the first boot)"
    if ! run swapoff -- "${device}"; then
      warn "could not turn the swap on ${device} off; leaving it untouched"
      return 0
    fi
  else
    log "${device} is not in use as swap; zeroing it as it is"
  fi

  # The device must not be in use while it is overwritten, so the check is made
  # again after swapoff rather than trusting it to have succeeded.
  if is_active_swap "${device}"; then
    warn "${device} is still in use as swap; leaving it untouched"
    return 0
  fi

  log "zeroing ${device}"
  if ! zero_device "${device}"; then
    warn "dd stopped before the end of ${device}; the tail keeps the old contents"
  fi

  if [[ -n "${swap_uuid}" ]]; then
    run mkswap -U "${swap_uuid}" -- "${device}" \
      || warn "could not re-create the swap signature on ${device} with UUID ${swap_uuid}"
  else
    warn "no swap UUID was found for ${device}; re-creating it with a new UUID, which invalidates its /etc/fstab entry"
    run mkswap -- "${device}" \
      || warn "could not re-create the swap signature on ${device}"
  fi
}

# zero_device <device>
# Writes zeros over a whole swap device. A block device ends the write on its
# own - dd stops at the end of the partition - but a swap *file* does not: an
# unbounded `dd of=<file>` grows the file until the filesystem is full, so the
# write to a file is bounded by its own size, rounded up to whole blocks (which
# leaves the file on a block boundary, so a second run does not grow it again).
zero_device() {
  local device="$1"
  local device_bytes=""
  local -a dd_arguments=( if=/dev/zero "of=${device}" "bs=${ZERO_BLOCK_SIZE}" )

  if [[ -b "${device}" ]]; then
    log "zeroing the block device ${device}; this takes as long as the device is large"
    dd "${dd_arguments[@]}"
    return $?
  fi

  device_bytes="$(stat -c %s -- "${device}" 2>/dev/null || printf '')"
  if [[ -z "${device_bytes}" ]]; then
    warn "could not read the size of ${device}; leaving it untouched"
    return 1
  fi

  log "zeroing the swap file ${device} (${device_bytes} bytes)"
  dd_arguments+=( "count=$(( (device_bytes + MEBIBYTE - 1) / MEBIBYTE ))" )
  dd "${dd_arguments[@]}"
}

# 7. The free space is filled with zeros so the datastore stores a thin image
#    (the hypervisor does not keep blocks that were never written, but it also
#    cannot know that blocks a deleted file left behind are free). Whatever the
#    fill leaves in the page cache is flushed to the disk at the end: Packer
#    powers the guest off as soon as this provisioner returns, and a shutdown
#    that races the write-back would drop the zeros again.
zero_free_space() {
  log "Step 7/8: filling the free space with zeros"

  if [[ "${ZERO_FREE_SPACE}" != "1" ]]; then
    log "skipping: ZERO_FREE_SPACE=0"
    return 0
  fi

  fill_filesystem_with_zeros "/" "${FREE_SPACE_FILLER}"

  if is_mountpoint "${BOOT_DIR}"; then
    fill_filesystem_with_zeros "${BOOT_DIR}" "${BOOT_FILLER}"
  else
    log "${BOOT_DIR} is not a separate filesystem; the fill of / covers its free space too"
  fi

  log "flushing the page cache to the disk"
  run sync || warn "sync failed"
}

# fill_filesystem_with_zeros <mountpoint> <filler>
# Writes zeros until the filesystem is full, then deletes the filler. dd ends
# with "No space left on device" at that point, which is the expected outcome
# and not a failure.
fill_filesystem_with_zeros() {
  local mount_point="$1"
  local filler="$2"
  local free_kib=""

  if [[ ! -d "${mount_point}" ]]; then
    warn "${mount_point} does not exist; nothing to fill"
    return 0
  fi

  free_kib="$(df -Pk -- "${mount_point}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ -z "${free_kib}" ]]; then
    warn "could not read the free space of ${mount_point}; skipping the fill"
    return 0
  fi
  if (( free_kib < FILL_MINIMUM_KIB )); then
    log "only ${free_kib} KiB free on ${mount_point}; skipping the fill"
    return 0
  fi

  if (( DRY_RUN )); then
    log "DRY-RUN would fill the ${free_kib} KiB of free space on ${mount_point} with zeros"
    return 0
  fi

  log "filling the ${free_kib} KiB of free space on ${mount_point} with zeros"
  if ! dd if=/dev/zero of="${filler}" bs="${ZERO_BLOCK_SIZE}"; then
    if [[ -e "${filler}" ]]; then
      log "dd stopped when ${mount_point} ran out of space (expected)"
    else
      warn "could not write ${filler}: ${mount_point} is read-only or has no room"
    fi
  fi

  if [[ -e "${filler}" ]]; then
    rm -f -- "${filler}"
    log "removed ${filler}"
  fi
}

# 8. The build log is the only record of the state the image was captured in, so
#    the disk usage and the ending network configuration are printed. Both are
#    read-only: they run under --dry-run too. The original ran ifconfig twice,
#    unquoted, and trusted it to be installed: net-tools is still in the
#    @standard group the RHEL kickstarts install, but it is deprecated, absent
#    from a minimal install, and under `sh -eux` a missing ifconfig aborts the
#    run. `ip` is used where it is available, and the same output is no longer
#    printed twice.
report_final_state() {
  log "Step 8/8: reporting the disk usage and the network configuration"

  log "disk usage before cleanup:"
  log_block "${DISK_USAGE_BEFORE_CLEANUP}"

  log "disk usage after cleanup:"
  log_block "$(df -hP 2>/dev/null || true)"

  log "network configuration at the end of cleanup:"
  if command -v ip >/dev/null 2>&1; then
    log_block "$(ip -brief address 2>/dev/null || true)"
  elif command -v ifconfig >/dev/null 2>&1; then
    warn "'ip' is not available; reporting the network configuration with ifconfig"
    log_block "$(ifconfig 2>/dev/null || true)"
  else
    warn "neither 'ip' nor 'ifconfig' is available; the network configuration is not reported"
  fi
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./cleanup.sh [--dry-run] [--help]

Shrinks a RHEL guest before it is captured as a template: resets the machine
identity, clears the temporary directories, the login records and the logs,
disables IPv6, zeroes the swap space and the free space on disk, and reports
the resulting disk usage and network configuration.

Options:
  --dry-run   Print every change that would be made, changing nothing.
  --help      Show this message.

Environment overrides (see the header of this script): ZERO_SWAP,
ZERO_FREE_SPACE, RESET_MACHINE_ID, ALLOW_NON_ROOT, SWAP_DEVICES.

prep.sh does the rest of the generalization (entitlement, SSH host keys,
hostname, package cache, shell history); this script runs after it.
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
  local command_name
  for command_name in "${REQUIRED_COMMANDS[@]}"; do
    require_command "${command_name}"
  done
}

main() {
  parse_arguments "$@"

  SCRIPT_PATH="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"

  require_root "$@"
  check_requirements

  # Captured before the first step so the log shows what the cleanup reclaimed.
  DISK_USAGE_BEFORE_CLEANUP="$(df -hP 2>/dev/null || true)"

  if (( DRY_RUN )); then
    log "dry-run mode: no changes will be made to $(hostname)"
  else
    log "starting cleanup on $(hostname)"
  fi

  reset_machine_identity
  purge_temp_directories
  disable_ipv6
  clear_login_records
  clear_log_files
  clear_swap
  zero_free_space
  report_final_state

  log "cleanup complete (${TRUNCATED_COUNT} file(s) emptied, ${REMOVED_COUNT} path(s) removed)"
}

# Run only when executed directly, so the script stays sourceable for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
