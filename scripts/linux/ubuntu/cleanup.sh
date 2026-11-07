#!/bin/sh
#
# cleanup.sh - final step of an Ubuntu Server Packer build.
#
# Generalises the guest so the clones made from it do not inherit the build
# host's identity, and shrinks it so the template the datastore stores is as
# small as it can be. The steps and their purpose are the ones the original
# script had; what changed is that each one is now bounded, idempotent, safe to
# re-run, and loud about what it did - or about what it could not do.
#
# Steps:
#    1. Reset the systemd machine identity (machine-id, the dbus copy, the
#       random seed). Clones that share it corrupt each other's journals.
#    2. Clear /tmp and /var/tmp, sparing the copy of this script that Packer is
#       still reading.
#    3. Drop the package caches and the orphaned dependencies.
#    4. Disable IPv6 for the next boot through a sysctl drop-in.
#    5. Hand the guest back to cloud-init: remove the installer's drop-ins, its
#       netplan file and its datasource settings, name the VMware datasource and
#       leave VMware customisation enabled.
#    6. Empty GRUB_CMDLINE_LINUX_DEFAULT and regenerate the boot configuration.
#    7. Clear the login records.
#    8. Clear the host logs, journald's included.
#    9. Whiteout the swap space and re-create its signature with the same UUID,
#       so /etc/fstab keeps resolving. Swap stays off until the clone boots.
#   10. Fill the free space with zeros, which is what lets the datastore store a
#       thinner template, and flush the page cache before Packer powers off.
#   11. Report the disk usage and the network configuration.
#
# The script is idempotent: running it twice leaves the same image as running it
# once. Nothing it does depends on the order it is run against other scripts,
# although on an Ubuntu build it belongs last, after netreset.sh.
#
# Usage: sudo ./cleanup.sh [--dry-run] [-v] [--help]
#
#   -n, --dry-run   Print every change that would be made, change nothing. Safe
#                   to run on any machine, including a workstation.
#   -v, --verbose   Trace every command (set -x). Packer runs this script with
#                   -x already, but the trace is turned back off below unless
#                   this option or TRACE=1 asks for it, so the build log keeps
#                   the script's own summary instead of every expansion.
#   -h, --help      This message.
#
# Environment overrides (all optional):
#
#   TRACE=1                 same as -v
#   RESET_MACHINE_ID=0      keep /etc/machine-id
#   ZERO_SWAP=0             leave the swap space alone
#   ZERO_FREE_SPACE=0       do not fill the free space
#   FILL_MOUNTPOINTS=...    mount points to fill (default: / /boot /var /var/log)
#
# NOTE - this file is POSIX sh on purpose. The Ubuntu templates in
# builds/linux/ubuntu/* run their scripts with bash
#
#     {{.Vars}} sudo -S -E bash -eux '{{.Path}}'
#
# and this file runs unchanged under bash. It also runs under dash, the /bin/sh
# of Ubuntu, so `sh cleanup.sh -v` by hand behaves identically. The other
# scripts in this directory are bash: apt.sh and finalupdate.sh use arrays,
# [[ ]], set -o pipefail, trap ... ERR and a decorated PS4 built from $LINENO,
# none of which exist in dash - starting them with sh is what a Packer build
# used to die on, as "trap: ERR: bad trap". Those two are launched with bash by
# the templates and re-execute themselves under bash if anything else starts
# them, so this file needs neither.
# (`local` is not in POSIX either, but every shell that can run this file has
# it: dash, ash, bash and ksh all implement it.)
#
# NOTE - Packer runs the script with errexit and treats a non-zero exit as a
# failed image build. Every failure path here is deliberate: the EXIT trap names
# the step that died, so a build log says "failed during: Step 8/11: clearing the
# host logs" instead of stopping in silence halfway down a traced log.
#
# NOTE - the two things this script deliberately does NOT do:
#
#   * /var/lib/wtmpdb. Ubuntu 24.04 records logins in a sqlite database kept by
#     wtmpdb instead of /var/log/wtmp, and PAM writes to it on every login.
#     Emptying or deleting a database from the outside is not safe - the file
#     left behind is either an empty database or a schema-less one, and neither
#     is something to hand to the PAM stack of an image nobody can log in to
#     yet. It is reported (step 7) and left for the operator to decide.
#   * /var/lib/cloud. cloud-init's per-instance state is left in place, exactly
#     as the original left it. Run `cloud-init clean --logs` in the image if the
#     clones from it are expected to re-run first-boot configuration.
#
# Modified from boxcutter (https://github.com/boxcutter). What changed, and why:
#
#   * `set -e` and `set -x` ran unconditionally: the trace flooded the build log
#     with every expansion, and a failure stopped the build with no explanation
#     of which step had failed. Tracing is opt-in now, the trap reports the
#     failing step, and every message is stamped and prefixed like the messages
#     in apt.sh and finalupdate.sh.
#
#   * `rm -rf /tmp/*` left dotfiles behind and unlinked the copy of this script
#     Packer had uploaded to /tmp, which survives only by accident of the open
#     file descriptor. The directories are emptied entry by entry now, and the
#     running script is spared explicitly. /var/tmp is cleared as well.
#
#   * The log wipe - `find /var/log -type f | while read f; do echo -ne '' >
#     "${f}"; done` - relied on echo understanding -n/-e, which dash's echo does
#     not: it would have written the string "-ne" into every log file. Files are
#     emptied with truncate now, which keeps their ownership, mode and ACLs, and
#     journald's binary journal files are deleted instead of emptied, because an
#     emptied journal file is a corrupt journal file. The wipe also ran before
#     the swap, GRUB and cloud-init steps, so the messages those wrote landed in
#     the image afterwards; it is the last step that touches /var/log now.
#
#   * The swap whiteout took the UUID from the last swap device blkid listed and
#     resolved /dev/disk/by-uuid/<uuid> from it, which is an empty string when
#     udev has not populated that directory - `swapoff ""`, `dd of=""`. Every
#     swap space this machine owns is cleared now: what the kernel is swapping
#     on, and what /etc/fstab declares as swap (by device, by UUID or by path,
#     which is how a swap file such as /swap.img is found). Each one is checked
#     for a swap signature and for being out of use before anything is written
#     to it, and the write is bounded, so a swap file can no longer be grown
#     until its filesystem is full.
#
#   * The free-space whiteout only covered /. The /boot whiteout the original
#     kept commented out is in place (skipped when /boot is not a filesystem of
#     its own), and so is /var and /var/log: those are the two filesystems whose
#     contents step 3 and step 8 delete, so their freed blocks are the ones
#     worth handing back to the datastore.
#
#   * The GRUB sed matched nothing - and said nothing - when the line was absent
#     or quoted differently, and update-grub's output was discarded, so a failed
#     regeneration looked like a successful one. The line is reported before and
#     after, a missed edit fails the build, and the kernel line the clones will
#     actually boot with is read back out of the regenerated configuration.
#
#   * The IPv6 sysctl file was written with two appends; it is one whole-file
#     write now. The cloud-init setting the original appended to cloud.cfg is a
#     cloud.cfg.d drop-in, which is both the way cloud-init expects to be
#     overridden and idempotent - appending grew the file on every run.
#
#   * apt was invoked without the options that make it non-interactive: dpkg
#     still asks about modified conffiles and needrestart (Ubuntu 22.04+) asks
#     before restarting a service, either of which hangs an unattended build.
#     The package steps are pinned non-interactive and made to wait for the dpkg
#     lock rather than fail when something else holds it.

# `local` is not in POSIX either, but every shell that can run this file has it
# (dash, ash, bash, ksh), and hand-scoping every loop variable is worse than the
# portability the rest of the script keeps. This is the only lint exception in
# the file; everything else is written to pass ShellCheck's POSIX sh rules.
# shellcheck disable=SC3043

set -eu

readonly PROGRAM_NAME="${0##*/}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
readonly LOG_DIR=/var/log
readonly JOURNAL_DIR=/var/log/journal
readonly WTMPDB_DIR=/var/lib/wtmpdb

# Emptying these two rather than deleting them makes systemd generate fresh
# ones on the first boot of every clone; a missing machine-id leaves the host
# in a degraded state instead.
readonly MACHINE_ID_FILE=/etc/machine-id
readonly DBUS_MACHINE_ID_FILE=/var/lib/dbus/machine-id
readonly RANDOM_SEED_FILE=/var/lib/systemd/random-seed

readonly IPV6_SYSCTL_FILE=/etc/sysctl.d/60-disable_ipv6.conf

readonly CLOUD_CFG_DIR=/etc/cloud/cloud.cfg.d
readonly CLOUD_DATASOURCE_FILE=/etc/cloud/cloud.cfg.d/90_dpkg.cfg
readonly CLOUD_VMWARE_FILE=/etc/cloud/cloud.cfg.d/91-disable-vmware-customization.cfg
readonly NETPLAN_INSTALLER_FILE=/etc/netplan/00-installer-config.yaml

readonly GRUB_DEFAULT_FILE=/etc/default/grub
readonly GRUB_CFG_FILE=/boot/grub/grub.cfg

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
readonly APT_LOCK_TIMEOUT=120       # seconds to wait for /var/lib/dpkg/lock
readonly FILLER_NAME=EMPTY          # free-space filler, one per mount point
readonly ZERO_BLOCK_SIZE=1M         # dd block size for zeroing
readonly MEBIBYTE=1048576           # the same size in bytes, for arithmetic
readonly FILL_MINIMUM_KIB=16384     # below this much free space, do not fill

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
DRY_RUN=${DRY_RUN:-0}
TRACE=${TRACE:-0}
RESET_MACHINE_ID=${RESET_MACHINE_ID:-1}
ZERO_SWAP=${ZERO_SWAP:-1}
ZERO_FREE_SPACE=${ZERO_FREE_SPACE:-1}

# Space is only reclaimed where this script has just deleted something: / (the
# bulk of the build's writes), /boot and /var (the package caches), and /var/log
# (the logs). /home, /opt and /tmp are left alone - filling a filesystem that was
# never written to burns minutes of build time to store zeros that are not there
# yet. Override the list to fill more.
FILL_MOUNTPOINTS=${FILL_MOUNTPOINTS:-'/ /boot /var /var/log'}

SCRIPT_PATH=''
WORK_FILE=''
DISK_USAGE_BEFORE_CLEANUP=''
TRUNCATED_COUNT=0
REMOVED_COUNT=0
CURRENT_STEP=startup
REPORTED=0

# ---------------------------------------------------------------------------
# Logging and failure reporting
# ---------------------------------------------------------------------------
timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()       { printf '[%s] %s\n' "$(timestamp)" "$*"; }
warn()      { printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2; }

die() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  REPORTED=1
  exit 1
}

# log_block <text>
# Logs a block of text one line at a time, so the output of df or ip carries the
# same prefix as everything else in the build log.
log_block() {
  printf '%s\n' "$1" | while IFS= read -r line; do
    if [ -n "$line" ]; then
      log "  $line"
    fi
  done
}

# step <text>
# Opens a step: recorded, so that both the trace and the failure report can name
# the step that is running, and logged, so the build log reads as a list of what
# was done rather than a wall of output.
step() {
  CURRENT_STEP=$1
  log "$1"
}

# The EXIT trap is the POSIX stand-in for the ERR trap the other scripts use:
# dash has no ERR signal. `set -e` exits with the failing command's status, the
# trap prints the step that was running, and the status the build sees is
# unchanged.
on_exit() {
  local status=$?

  # A failure that went through die() has already been reported with its own
  # message; this second report is for the commands that die without a word
  # under `set -e`, which is exactly when the step name matters.
  if [ "$status" -ne 0 ] && [ "$REPORTED" -ne 1 ]; then
    printf '[%s] ERROR: %s failed (exit %s) during: %s\n' \
      "$(timestamp)" "$PROGRAM_NAME" "$status" "$CURRENT_STEP" >&2
    printf '  re-run with -v for a command-by-command trace\n' >&2
  fi

  remove_work_file
  exit "$status"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Options and preconditions
# ---------------------------------------------------------------------------
validate_flag() {
  # validate_flag <name> <value>
  case $2 in
    0 | 1) ;;
    *) die "$1 must be 0 or 1 (got '$2')" ;;
  esac
}

# Tracing: Packer passes -x on the command line, which cannot be undone from the
# outside; it can from the inside, and that is what happens unless -v/TRACE=1
# asked for the trace.
configure_tracing() {
  if [ "$TRACE" -eq 1 ]; then
    # Every traced line names the step it belongs to, which is what makes a
    # trace usable when there is no line number to print here (dash has none).
    PS4='+ [${CURRENT_STEP}] '
    set -x
  else
    set +x
  fi
}

# require_root
# Packer runs the script through sudo, so this is for the human who runs it
# directly: re-execute under sudo once rather than failing halfway through a
# step that needed root.
require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    warn 'not running as root; a real run would re-execute itself through sudo'
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || die 'must run as root, and sudo is not installed'
  log 'not running as root; re-executing through sudo'
  exec sudo sh "$0" "$@"
}

# require_command <name>
require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "required command '$1' is not installed (tolerated under --dry-run)"
    return 0
  fi

  die "required command is not installed: $1"
}

check_requirements() {
  for command_name in apt-get awk dd df find grep mktemp sed sync truncate; do
    require_command "$command_name"
  done
}

# run <command> [args...]
# Runs a command that changes the host, under --dry-run reporting it instead.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would execute: $*"
    return 0
  fi

  "$@"
}

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------
# truncate_file <path>...
# Empties files in place, which keeps their ownership, mode and ACLs - the
# reason wtmp, btmp and lastlog have to be emptied rather than replaced.
truncate_file() {
  local target

  for target in "$@"; do
    if [ ! -f "$target" ]; then
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN would empty $target"
      continue
    fi

    if truncate -s 0 -- "$target" 2>/dev/null; then
      TRUNCATED_COUNT=$(( TRUNCATED_COUNT + 1 ))
    else
      warn "could not empty $target (immutable or append-only attribute?)"
    fi
  done
}

# remove_path <path>...
# Removes files and directories. A path that cannot be removed fails the build:
# the files this is used on are the ones that must not survive into the image
# (the installer's network configuration, for one).
remove_path() {
  local target

  for target in "$@"; do
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN would remove $target"
      continue
    fi

    rm -rf -- "$target" || die "could not remove $target"
    log "removed $target"
    REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
  done
}

# purge_directory <directory>...
# Removes every entry inside a directory while keeping the directory itself.
# Keeping it matters for /var/log/journal: without the directory journald falls
# back to non-persistent storage.
purge_directory() {
  local target

  for target in "$@"; do
    if [ ! -d "$target" ]; then
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN would remove the contents of $target"
      continue
    fi

    # Never unlink the copy of this script Packer is still reading: it uploads
    # it to /tmp, and the shell reads a script incrementally, so whether
    # removing it mid-run is safe depends on how much of the file is unread.
    if [ -n "$SCRIPT_PATH" ] && [ -e "$SCRIPT_PATH" ]; then
      find "$target" -mindepth 1 -maxdepth 1 ! -samefile "$SCRIPT_PATH" \
        -exec rm -rf -- '{}' '+' || die "could not empty $target"
    else
      find "$target" -mindepth 1 -maxdepth 1 \
        -exec rm -rf -- '{}' '+' || die "could not empty $target"
    fi

    log "emptied $target"
  done
}

# write_file <path> <content>
# Replaces a small configuration file. Writing the whole file rather than
# appending to it is what makes a second run leave the same bytes behind.
write_file() {
  local path="$1" content="$2" directory

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would write $path:"
    log_block "$content"
    return 0
  fi

  directory=${path%/*}
  if [ ! -d "$directory" ]; then
    run mkdir -p -- "$directory" || {
      warn "could not create $directory"
      return 0
    }
  fi

  if printf '%s\n' "$content" > "$path"; then
    log "wrote $path:"
    log_block "$content"
  else
    warn "could not write $path"
  fi
}

# create_work_file
# A scratch file for the list of log files, kept in /run: that is a tmpfs, so
# even if this script is killed before it removes the file, the file cannot end
# up inside the sealed image the way a file in /tmp would.
create_work_file() {
  WORK_FILE=$(mktemp /run/cleanup-list.XXXXXX) ||
    die 'could not create a scratch file in /run'
}

remove_work_file() {
  if [ -n "$WORK_FILE" ] && [ -e "$WORK_FILE" ]; then
    rm -f -- "$WORK_FILE" 2>/dev/null || :
    WORK_FILE=''
  fi
}

# ---------------------------------------------------------------------------
# Mount and swap helpers
# ---------------------------------------------------------------------------
# is_mountpoint <path>
# True when the path is a filesystem of its own, read straight out of the
# kernel's mount table, so a /boot that is a plain directory on / is not filled
# twice.
is_mountpoint() {
  awk -v target="$1" '$2 == target { found = 1 } END { exit !found }' /proc/mounts
}

# is_swap_device <device>
# True only when blkid recognises a swap signature on the device. The whiteout
# destroys whatever a device holds, so nothing is zeroed on a guess.
is_swap_device() {
  if ! command -v blkid >/dev/null 2>&1; then
    return 1
  fi

  [ "$(blkid -o value -s TYPE -- "$1" 2>/dev/null || true)" = swap ]
}

# is_active_swap <device>
# True when the kernel uses the device as swap. /proc/swaps lists the path the
# kernel knows the device by, which is not always the path blkid prints (an LVM
# alias such as /dev/mapper/sysvg-lv_swap, for instance), so the full path, its
# resolved target and its basename are all accepted.
is_active_swap() {
  local device="$1" device_name resolved_device

  device_name=${device##*/}
  resolved_device=$(readlink -f -- "$device" 2>/dev/null || true)
  if [ -z "$resolved_device" ]; then
    resolved_device=$device
  fi

  awk -v device="$device" -v name="$device_name" -v resolved="$resolved_device" \
    'NR > 1 && ($1 == device || $1 == name || $1 == resolved) { found = 1 } END { exit !found }' \
    /proc/swaps
}

# is_fstab_swap_device <device>
# True when /etc/fstab mounts the device as swap, named by path, by UUID or by
# label. The UUID is compared against blkid's value rather than resolved through
# /dev/disk/by-uuid, because on a host whose udev has not populated that
# directory the symlink is not there - the failure mode the original script had.
is_fstab_swap_device() {
  local device="$1" uuid='' label=''

  if [ ! -r /etc/fstab ]; then
    return 1
  fi

  uuid=$(blkid -o value -s UUID -- "$device" 2>/dev/null || true)
  label=$(blkid -o value -s LABEL -- "$device" 2>/dev/null || true)

  awk -v device="$device" -v uuid="$uuid" -v label="$label" '
    $3 == "swap" {
      if ($1 == device) { found = 1 }
      if (uuid != "" && $1 == "UUID=" uuid) { found = 1 }
      if (label != "" && $1 == "LABEL=" label) { found = 1 }
    }
    END { exit !found }' /etc/fstab
}

# list_swap_devices
# Prints the path of every swap space to clear, one per line, deduplicated.
#
# Two sources are consulted, because neither of them sees everything:
#
#   * /proc/swaps - what this kernel is swapping on right now. It is the only
#     source that sees a swap *file*, which blkid's block-device scan cannot
#     report, and a swap the kernel is using is this machine's swap by
#     definition.
#
#   * blkid's block devices that carry a swap signature - which is what finds
#     the swap space of these images, an LVM logical volume that is configured
#     but off during the build. A device found this way is only cleared when
#     /etc/fstab mounts it as swap: the whiteout destroys whatever a device
#     holds, and a block device that merely happens to carry a swap signature -
#     a second disk, a stick that was once a swap device - is not this image's
#     to wipe.
#
# The original asked blkid for the UUID of the last swap device it listed and
# looked that up under /dev/disk/by-uuid; when udev has not populated that
# directory the lookup produced an empty string, so swapoff and dd were handed
# "".
list_swap_devices() {
  local active_devices='' configured_devices='' device

  active_devices=$(awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null || true)

  if command -v blkid >/dev/null 2>&1; then
    if [ ! -r /etc/fstab ]; then
      warn '/etc/fstab is not readable: only the swap this kernel is using will be cleared'
    fi

    # Word splitting is intended: blkid prints one device path per line and none
    # of them can contain a space.
    # shellcheck disable=SC2046
    for device in $(blkid -o device -t TYPE=swap 2>/dev/null || true); do
      if is_fstab_swap_device "$device"; then
        configured_devices=$(printf '%s\n%s' "$configured_devices" "$device")
      fi
    done
  fi

  # A swap space that /etc/fstab names by path - a swap *file* such as
  # /swap.img, or a partition - is reported by neither source above when it is
  # not in use: /proc/swaps only lists a swap the kernel has, and blkid only
  # scans block devices. It is checked for a swap signature before it is
  # accepted, so the entry alone never authorises a wipe. UUID= and LABEL=
  # entries are left to the blkid scan above, because a file is not in the
  # database those are resolved against.
  if [ -r /etc/fstab ]; then
    # shellcheck disable=SC2046
    for device in $(awk '$3 == "swap" && $1 ~ /^\// { print $1 }' /etc/fstab 2>/dev/null || true); do
      if [ -e "$device" ] && is_swap_device "$device"; then
        configured_devices=$(printf '%s\n%s' "$configured_devices" "$device")
      fi
    done
  fi

  # NR > 1 skips the header of /proc/swaps, `NF` drops the blank lines the empty
  # sources leave behind, and `!seen[$0]++` prints each path once.
  printf '%s\n%s\n' "$active_devices" "$configured_devices" |
    awk 'NF && !seen[$0]++'
}

# zero_device <device>
# Writes zeros over a swap device. A block device ends the write on its own -
# dd stops at the end of the partition - but a swap *file* does not: an
# unbounded `dd of=<file>` grows the file until its filesystem is full, so a
# write to a file is bounded by the file's own size, rounded up to whole blocks.
zero_device() {
  local device="$1" device_bytes

  if [ -b "$device" ]; then
    log "zeroing the block device $device; this takes as long as the device is large"
    dd if=/dev/zero "of=$device" "bs=$ZERO_BLOCK_SIZE"
    return $?
  fi

  device_bytes=$(stat -c %s -- "$device" 2>/dev/null || true)
  if [ -z "$device_bytes" ]; then
    warn "could not read the size of $device; leaving it untouched"
    return 1
  fi

  log "zeroing the swap file $device ($device_bytes bytes)"
  dd if=/dev/zero "of=$device" "bs=$ZERO_BLOCK_SIZE" \
    "count=$(( (device_bytes + MEBIBYTE - 1) / MEBIBYTE ))"
}

# fill_filesystem_with_zeros <mountpoint>
# Writes zeros until the filesystem is full, then deletes the filler. dd ends
# with "No space left on device" at that point, which is the point of the
# exercise and not a failure.
fill_filesystem_with_zeros() {
  local mount_point="$1" filler free_kib

  if [ ! -d "$mount_point" ]; then
    warn "$mount_point does not exist; nothing to fill"
    return 0
  fi

  case $mount_point in
    /) filler=/$FILLER_NAME ;;
    */) filler=${mount_point}$FILLER_NAME ;;
    *) filler=$mount_point/$FILLER_NAME ;;
  esac

  free_kib=$(df -Pk -- "$mount_point" 2>/dev/null | awk 'NR == 2 { print $4 }')
  case $free_kib in
    '' | *[!0-9]*)
      warn "could not read the free space of $mount_point; skipping the fill"
      return 0
      ;;
  esac

  if [ "$free_kib" -lt "$FILL_MINIMUM_KIB" ]; then
    log "only ${free_kib} KiB free on $mount_point; skipping the fill"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would fill the ${free_kib} KiB of free space on $mount_point with zeros via $filler"
    return 0
  fi

  log "filling the ${free_kib} KiB of free space on $mount_point with zeros"
  if ! dd if=/dev/zero "of=$filler" "bs=$ZERO_BLOCK_SIZE"; then
    if [ -e "$filler" ]; then
      log "dd stopped when $mount_point ran out of space (expected)"
    else
      warn "could not write $filler: $mount_point is read-only or has no room"
    fi
  fi

  if [ -e "$filler" ]; then
    rm -f -- "$filler" || warn "could not remove $filler"
    log "removed $filler"
  fi
}
# ---------------------------------------------------------------------------
# 1. Machine identity
# ---------------------------------------------------------------------------
# /etc/machine-id is the identity systemd, journald and dbus key their state on:
# two clones sharing it corrupt each other's journals. It is emptied rather than
# deleted, so systemd generates a fresh one on the first boot of each clone.
# /var/lib/systemd/random-seed is entropy captured from the build host, and a
# shared seed is shared entropy, so it goes.
reset_machine_identity() {
  step 'Step 1/11: resetting the systemd machine identity'

  if [ "$RESET_MACHINE_ID" != 1 ]; then
    log 'skipping: RESET_MACHINE_ID=0'
    return 0
  fi

  truncate_file "$MACHINE_ID_FILE"

  if [ -L "$DBUS_MACHINE_ID_FILE" ]; then
    log "$DBUS_MACHINE_ID_FILE is a symlink to $(readlink -- "$DBUS_MACHINE_ID_FILE" 2>/dev/null || printf '?'); it follows the file emptied above"
  else
    truncate_file "$DBUS_MACHINE_ID_FILE"
  fi

  remove_path "$RANDOM_SEED_FILE"
}

# ---------------------------------------------------------------------------
# 2. Temporary directories
# ---------------------------------------------------------------------------
clear_temporary_directories() {
  step 'Step 2/11: clearing the temporary directories'

  # /tmp is where Packer uploads the scripts it runs, which is why the script
  # that is running has to be spared; /var/tmp is FHS-persistent, so nothing in
  # it belongs in an image either.
  purge_directory /tmp /var/tmp
}

# ---------------------------------------------------------------------------
# 3. Package caches
# ---------------------------------------------------------------------------
# apt-get with the options every call here needs: quiet, keeping the shipped
# configuration on a conffile conflict, and waiting for the dpkg lock instead of
# failing when another apt run holds it.
apt_get() {
  apt-get -q \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" \
    "$@"
}

# Orphaned dependencies and the downloaded .deb files are of no use to a clone.
# The run is pinned non-interactive first: dpkg asks about modified conffiles
# and needrestart (22.04 and later) asks before restarting a service, and either
# question hangs a build that has nobody at the console to answer it.
clear_package_caches() {
  step 'Step 3/11: clearing the package caches'

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a     # restart services when a library is replaced
  export UCF_FORCE_CONFFOLD=1   # keep the existing config for ucf-managed files

  run apt_get -y autoremove --purge
  run apt_get -y clean
  run apt_get -y autoclean
}

# ---------------------------------------------------------------------------
# 4. IPv6
# ---------------------------------------------------------------------------
# The drop-in turns IPv6 off on every current and future interface at boot. It is
# written as one whole file rather than two appends, and the running kernel is
# deliberately left alone: the build's own session may be reachable over IPv6,
# and finalupdate.sh already puts ipv6.disable=1 on the kernel command line for
# the boot that follows.
disable_ipv6() {
  step 'Step 4/11: disabling IPv6 for the next boot'

  write_file "$IPV6_SYSCTL_FILE" \
    'net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1'
}

# ---------------------------------------------------------------------------
# 5. cloud-init
# ---------------------------------------------------------------------------
# The installer's files describe the build host, not the clones made from it:
# subiquity's network override, the installer's own datasource settings and the
# installer's netplan file all have to go, the datasource list has to name the
# VMware source so a deployed copy reads the settings vSphere customisation
# writes into it, and VMware customisation has to stay enabled
# (disable_vmware_customization: false) for that to happen.
#
# The original appended that key to /etc/cloud/cloud.cfg, which grew the file on
# every run and would have grown it again on the second run of the script; it is
# a cloud.cfg.d drop-in now, which is both idempotent and the way cloud-init is
# meant to be overridden.
prepare_cloud_init() {
  step 'Step 5/11: handing the guest back to cloud-init'

  remove_path \
    "$CLOUD_CFG_DIR/subiquity-disable-cloudinit-networking.cfg" \
    "$CLOUD_CFG_DIR/99-installer.cfg" \
    "$NETPLAN_INSTALLER_FILE"

  write_file "$CLOUD_VMWARE_FILE" 'disable_vmware_customization: false'
  write_file "$CLOUD_DATASOURCE_FILE" 'datasource_list: [ VMware, OVF, None ]'
}

# ---------------------------------------------------------------------------
# 6. GRUB
# ---------------------------------------------------------------------------
# The parameter list is emptied rather than extended because that is what the
# original did: the clones boot with the kernel's own defaults and a visible
# console instead of the installer's "quiet splash".

# grub_default_line
# The effective GRUB_CMDLINE_LINUX_DEFAULT line, or the empty string when there
# is none (the line removed, or commented out).
grub_default_line() {
  grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE" 2>/dev/null |
    tail -n 1
}

regenerate_grub_configuration() {
  # The output is no longer discarded: hiding it made a failed or skipped
  # regeneration look exactly like a successful one.
  if command -v update-grub >/dev/null 2>&1; then
    run update-grub ||
      warn 'update-grub failed; the kernel command line change may not be in the boot configuration'
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    run grub-mkconfig -o "$GRUB_CFG_FILE" ||
      warn "could not regenerate $GRUB_CFG_FILE"
  else
    warn 'neither update-grub nor grub-mkconfig is installed; the change takes effect the next time the boot configuration is generated'
  fi
}

# report_boot_kernel_line
# Reads the kernel line back out of the configuration the firmware actually
# loads, so the build log records what the GRUB edit produced rather than what
# was asked for.
report_boot_kernel_line() {
  local kernel_line

  if [ ! -f "$GRUB_CFG_FILE" ]; then
    warn "$GRUB_CFG_FILE does not exist; the kernel command line is not reported"
    return 0
  fi

  kernel_line=$(grep -m 1 -E '^[[:space:]]*(linux|linuxefi)[[:space:]]' "$GRUB_CFG_FILE" 2>/dev/null || true)
  if [ -n "$kernel_line" ]; then
    log "boots with: $kernel_line"
  else
    warn "no kernel line found in $GRUB_CFG_FILE"
  fi
}

empty_grub_kernel_command_line() {
  step 'Step 6/11: emptying the GRUB kernel command line'

  if [ ! -f "$GRUB_DEFAULT_FILE" ]; then
    warn "$GRUB_DEFAULT_FILE does not exist; the kernel command line is left as it is"
    return 0
  fi

  local before line
  before=$(grub_default_line)

  case $before in
    '')
      warn "no GRUB_CMDLINE_LINUX_DEFAULT line in $GRUB_DEFAULT_FILE; nothing to empty"
      return 0
      ;;
    *'GRUB_CMDLINE_LINUX_DEFAULT=""')
      log 'GRUB_CMDLINE_LINUX_DEFAULT is already empty'
      ;;
    *)
      log "was: $before"
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN would set GRUB_CMDLINE_LINUX_DEFAULT=\"\" in $GRUB_DEFAULT_FILE"
        return 0
      fi

      sed -i -E 's|^([[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=).*$|\1""|' "$GRUB_DEFAULT_FILE" ||
        die "could not edit $GRUB_DEFAULT_FILE"

      # Confirm the edit landed before reporting success: a sed whose pattern
      # matched nothing leaves the file exactly as it was.
      line=$(grub_default_line)
      case $line in
        *'GRUB_CMDLINE_LINUX_DEFAULT=""')
          log "now: $line"
          ;;
        *)
          die "GRUB_CMDLINE_LINUX_DEFAULT is still not empty in $GRUB_DEFAULT_FILE"
          ;;
      esac
      ;;
  esac

  regenerate_grub_configuration
  report_boot_kernel_line
}
# ---------------------------------------------------------------------------
# 7. Login records
# ---------------------------------------------------------------------------
# wtmp, btmp, lastlog and faillog record who logged in to the build host and who
# failed to. They are emptied in place rather than deleted: `last` and `lastlog`
# expect the files to exist, and emptying keeps their ownership, mode and ACLs.
# (The original created them with a shell redirect when they were missing, which
# would have handed `last` a file owned by whatever the umask allowed.)
clear_login_records() {
  step 'Step 7/11: clearing the login records'

  local record_file
  for record_file in \
    "$LOG_DIR/wtmp" \
    "$LOG_DIR/btmp" \
    "$LOG_DIR/lastlog" \
    "$LOG_DIR/faillog"
  do
    if [ -e "$record_file" ]; then
      truncate_file "$record_file"
    else
      log "$record_file is not present; nothing to clear"
    fi
  done

  # Ubuntu 24.04 moved native login history out of /var/log/wtmp and into a
  # sqlite database under /var/lib/wtmpdb. See the note at the top of this file
  # for why the database is reported instead of emptied.
  if [ -d "$WTMPDB_DIR" ]; then
    warn "$WTMPDB_DIR exists: this release records logins in a database there, which this script deliberately leaves alone (see the header)"
  fi
}

# ---------------------------------------------------------------------------
# 8. Logs
# ---------------------------------------------------------------------------
clear_log_files() {
  step 'Step 8/11: clearing the host logs'

  # rsyslog holds /var/log/syslog and its neighbours open, and a process that
  # keeps writing to a file this script has just emptied leaves a sparse file:
  # the old contents gone, a hole where they were, the new lines after it. It is
  # stopped and left stopped - the image is powered off as soon as the build
  # finishes - and its boot-time enablement is untouched.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet rsyslog; then
    run systemctl stop rsyslog || warn 'could not stop rsyslog'
  fi

  # journald's journal files are binary and named after the machine-id emptied in
  # step 1: emptying one leaves journald holding a corrupt file, so the
  # directory's contents are deleted instead. The directory itself stays -
  # without it journald falls back to non-persistent storage.
  purge_directory "$JOURNAL_DIR"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would empty every remaining file under $LOG_DIR"
    return 0
  fi

  # Everything else under /var/log is emptied in place, which keeps its
  # ownership, mode and ACLs. The list is written to a file and read back rather
  # than piped into the loop, because a pipe would run the loop in a subshell and
  # the files-emptied count would be lost with it.
  local log_file
  create_work_file

  if ! find "$LOG_DIR" -type f ! -path "$JOURNAL_DIR/*" > "$WORK_FILE" 2>/dev/null; then
    warn "could not list every file under $LOG_DIR; some may be left unemptied"
  fi

  while IFS= read -r log_file; do
    truncate_file "$log_file"
  done < "$WORK_FILE"

  remove_work_file
}

# ---------------------------------------------------------------------------
# 9. Swap
# ---------------------------------------------------------------------------
# The swap space is whiteouted so the datastore does not store the gigabytes of
# stale pages the build host left in it, then re-created with the same UUID so
# the /etc/fstab entry keeps resolving. Swap is left off until the clone boots,
# which is also what makes mkswap's fresh signature - with no resume data - the
# right thing for a template to carry.
clear_swap() {
  step 'Step 9/11: clearing the swap space'

  if [ "$ZERO_SWAP" != 1 ]; then
    log 'skipping: ZERO_SWAP=0'
    return 0
  fi

  local devices
  devices=$(list_swap_devices)

  if [ -z "$devices" ]; then
    log 'no swap device found; nothing to clear'
    return 0
  fi

  local device
  while IFS= read -r device; do
    if [ -n "$device" ]; then
      clear_swap_device "$device"
    fi
  done <<EOF
$devices
EOF
}

# clear_swap_device <device>
# Zeroes one swap device and re-creates its swap signature. The device is
# checked before it is touched: the original asked blkid for a UUID and handed
# whatever /dev/disk/by-uuid/<uuid> resolved to - often the empty string - to
# swapoff, dd and mkswap without ever asking what it was.
clear_swap_device() {
  local device="$1" swap_uuid

  if ! is_swap_device "$device"; then
    warn "refusing to zero $device: it does not carry a swap signature"
    return 0
  fi

  swap_uuid=$(blkid -o value -s UUID -- "$device" 2>/dev/null || true)

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would turn $device off, zero it and re-create its swap signature with UUID ${swap_uuid:-<a new one>}"
    return 0
  fi

  if is_active_swap "$device"; then
    log "turning the swap on $device off (it stays off until the first boot)"
    if ! run swapoff -- "$device"; then
      warn "could not turn the swap on $device off; leaving it untouched"
      return 0
    fi
  else
    log "$device is not in use as swap; zeroing it as it is"
  fi

  # The device must not be in use while it is overwritten, so the check is made
  # again after swapoff instead of trusting it to have worked.
  if is_active_swap "$device"; then
    warn "$device is still in use as swap; leaving it untouched"
    return 0
  fi

  log "zeroing $device"
  if ! zero_device "$device"; then
    warn "dd stopped before the end of $device; its tail keeps the old contents"
  fi

  if [ -n "$swap_uuid" ]; then
    run mkswap -U "$swap_uuid" -- "$device" ||
      warn "could not re-create the swap signature on $device with UUID $swap_uuid"
  else
    warn "no swap UUID was found for $device; re-creating it with a new one invalidates its /etc/fstab entry"
    run mkswap -- "$device" ||
      warn "could not re-create the swap signature on $device"
  fi
}

# ---------------------------------------------------------------------------
# 10. Free space
# ---------------------------------------------------------------------------
# Filling the free space with zeros is what lets the datastore store a thinner
# template: the blocks a deleted file leaves behind are still allocated until
# something overwrites them. FILL_MOUNTPOINTS names the filesystems worth filling
# on these images - see the comment where it is set - and a mount point that is
# not a filesystem of its own is skipped, because the fill of / already covers
# its free space.
zero_free_space() {
  step 'Step 10/11: filling the free space with zeros'

  if [ "$ZERO_FREE_SPACE" != 1 ]; then
    log 'skipping: ZERO_FREE_SPACE=0'
    return 0
  fi

  # Word splitting is intended: FILL_MOUNTPOINTS is a space separated list of
  # paths, and none of them can contain a space.
  # shellcheck disable=SC2086
  local mount_point
  for mount_point in $FILL_MOUNTPOINTS; do
    if ! is_mountpoint "$mount_point"; then
      log "$mount_point is not a filesystem of its own; the fill of / covers its free space"
      continue
    fi

    fill_filesystem_with_zeros "$mount_point"
  done

  # Whatever the fills left in the page cache is flushed to the disk at the end:
  # Packer powers the guest off as soon as this provisioner returns, and a
  # shutdown that races the write-back would drop the zeros again.
  log 'flushing the page cache to the disk'
  run sync || warn 'sync failed'
}

# ---------------------------------------------------------------------------
# 11. Report
# ---------------------------------------------------------------------------
# The build log is the only record of the state the image was captured in, so the
# disk usage and the ending network configuration are printed. Both are read-only
# and run under --dry-run too.
report_final_state() {
  step 'Step 11/11: reporting the disk usage and the network configuration'

  log 'disk usage before cleanup:'
  log_block "$DISK_USAGE_BEFORE_CLEANUP"

  log 'disk usage after cleanup:'
  log_block "$(df -hP 2>/dev/null || true)"

  log 'network configuration:'
  if command -v ip >/dev/null 2>&1; then
    log_block "$(ip -brief address 2>/dev/null || true)"
  elif command -v ifconfig >/dev/null 2>&1; then
    log_block "$(ifconfig 2>/dev/null || true)"
  else
    log 'neither ip nor ifconfig is installed; the network configuration is not reported'
  fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./cleanup.sh [--dry-run] [-v] [--help]

Last step of an Ubuntu Server Packer build: resets the machine identity, clears
the temporary directories and the package caches, disables IPv6 for the next
boot, hands the guest back to cloud-init, empties the GRUB kernel command line,
clears the login records and the logs, whiteouts the swap space, fills the free
space with zeros and reports the resulting disk usage.

Options:
  -n, --dry-run   Print every change that would be made, change nothing.
  -v, --verbose   Trace every command (set -x).
  -h, --help      Show this message.

Environment overrides: TRACE, RESET_MACHINE_ID, ZERO_SWAP, ZERO_FREE_SPACE and
FILL_MOUNTPOINTS - see the header of this script. The script is idempotent and
safe to run again.
EOF
}

parse_arguments() {
  for argument in "$@"; do
    case $argument in
      -n | --dry-run) DRY_RUN=1 ;;
      -v | --verbose) TRACE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $argument (try --help)"
        ;;
    esac
  done
}

main() {
  parse_arguments "$@"

  validate_flag TRACE "$TRACE"
  validate_flag DRY_RUN "$DRY_RUN"
  validate_flag RESET_MACHINE_ID "$RESET_MACHINE_ID"
  validate_flag ZERO_SWAP "$ZERO_SWAP"
  validate_flag ZERO_FREE_SPACE "$ZERO_FREE_SPACE"

  # Before anything that would be traced without it: Packer runs this file with
  # -eux, and the trace is turned back off unless it was asked for.
  configure_tracing

  SCRIPT_PATH=$(readlink -f -- "$0" 2>/dev/null || true)
  if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH=$0
  fi

  # Command-line options survive the re-execution below because they are
  # arguments; a TRACE=1 in the environment does not, so pass -v instead when
  # running this by hand as a normal user.
  require_root "$@"
  check_requirements

  # Captured before the first step, so the log shows what the cleanup reclaimed.
  DISK_USAGE_BEFORE_CLEANUP=$(df -hP 2>/dev/null || true)

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run on $(hostname 2>/dev/null || printf 'this host'): no change will be made"
  else
    log "starting cleanup on $(hostname 2>/dev/null || printf 'this host')"
  fi

  reset_machine_identity
  clear_temporary_directories
  clear_package_caches
  disable_ipv6
  prepare_cloud_init
  empty_grub_kernel_command_line
  clear_login_records
  clear_log_files
  clear_swap
  zero_free_space
  report_final_state

  log "cleanup complete (${TRUNCATED_COUNT} file(s) emptied, ${REMOVED_COUNT} path(s) removed)"
}

# Run unconditionally: Packer executes this file, and the dry-run flag is what
# makes it testable, so there is nothing to gain from a "am I being sourced"
# test that POSIX sh cannot do reliably anyway.
main "$@"
