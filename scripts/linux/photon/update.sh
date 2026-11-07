#!/bin/bash
#
# update.sh - update and patch a Photon OS host on demand.
#
# This file used to run `yum update` / `yum upgrade`. yum does not exist on
# VMware Photon OS - tdnf is the package manager - so the script could only ever
# have failed, and it was never referenced by the build. It is kept as a
# convenient entry point on a deployed host, but it no longer carries its own
# copy of the update logic: it delegates to scripts/system/update-packages.sh,
# the script the Packer build runs as its final provisioner, so there is one
# implementation and one place to fix.
#
# Usage (on a Photon host, as root or through sudo):
#
#     sudo ./update.sh
#     sudo ./update.sh -v        # trace every command
#     sudo ./update.sh -h        # what the canonical script documents
#
# Every argument is passed straight through, so the environment overrides
# PHOTON_PATCH_MAX_ROUNDS, PHOTON_PATCH_ATTEMPTS and PHOTON_PATCH_STRICT work
# here exactly as they do in the canonical script.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly UPDATE_SCRIPT="${SCRIPT_DIR}/system/update-packages.sh"

if [[ ! -r "${UPDATE_SCRIPT}" ]]; then
  printf '%s: cannot find %s\n' "${0##*/}" "${UPDATE_SCRIPT}" >&2
  exit 1
fi

exec bash "${UPDATE_SCRIPT}" "$@"
