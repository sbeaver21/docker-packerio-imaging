#!/bin/sh
# =============================================================================
#  prepare-windows-iso.sh
#
#  Builds the F: scripts ISO for one Windows project, from a clean checkout.
#
#      ./scripts/bootstrap/prepare-windows-iso.sh \
#          builds/windows/server/2025-standard-core
#      ./scripts/bootstrap/prepare-windows-iso.sh \
#          builds/windows/server/2025-standard-core --upload
#
#  Why an ISO at all: the Windows templates attach this as the third CD rather
#  than using Packer's cd_files. On Linux, cd_files is written with xorriso in
#  Rock Ridge mode, which Windows cannot read - the guest reports "The volume
#  does not contain a recognized file system" for F:, every first-logon command
#  in the answer file fails, VMware Tools never installs, and Packer waits
#  forever at "Waiting for IP...". Joliet (-J) is readable by both.
#
#  The device order the guest depends on:
#      D:  Windows install ISO      (iso_paths[0])
#      E:  VMware Tools ISO         (iso_paths[1])
#      F:  this ISO                 (iso_paths[2])
#
#  --upload needs govc and GOVC_URL/GOVC_DATASTORE/GOVC_USERNAME/GOVC_PASSWORD,
#  and copies the ISO to packer-iso/<name> on the datastore the templates read.
# =============================================================================
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "${here}/../.." && pwd)
cd "$repo"

project="${1:?usage: prepare-windows-iso.sh <project-dir> [--upload]}"
upload="no"
[ "${2:-}" = "--upload" ] && upload="yes"

[ -d "$project" ] || { echo "no such project: $project" >&2; exit 1; }

# builds/windows/server/2025-standard-core -> 2025 + standard-core
name=$(basename "$project")
version=${name%%-*}
edition=${name#*-}
[ "$version" != "$name" ] || { echo "cannot read version/edition from ${name}" >&2; exit 1; }

files="builds/windows/files"


command -v xorriso >/dev/null 2>&1 || { echo "xorriso not on PATH" >&2; exit 1; }

root=$(mktemp -d)
outdir="builds/windows/packer-iso"
iso="${outdir}/win${version}-${edition}-scripts.iso"
mkdir -p "$outdir"
trap 'rm -rf "$root"' EXIT INT TERM

# The edition's own staging script. Each edition has a different static IP in
# temp-network.ps1 so parallel builds cannot collide.
if [ -d "${project}/${edition}" ]; then
    cp -a "${project}/${edition}/." "$root/"
else
    echo "warning: ${project}/${edition} not found - no temp-network.ps1" >&2
fi

# The shared flat scripts, same set the Windows host carries.
for f in "$files"/*.ps1; do
    case "$f" in *.bak*|*.backup*|*.save*|*.old*) continue ;; esac
    [ -f "$f" ] && cp -a "$f" "$root/"
done

# win-init.ps1 has $StageFolder = @('CD','Temp') and stages both to C:\.
[ -d "$files/CD" ]   && cp -a "$files/CD"   "$root/CD"
[ -d "$files/Temp" ] && cp -a "$files/Temp" "$root/Temp"

rm -f "$iso"
xorriso -as mkisofs -J -joliet-long -R -V PACKER_CD -o "$iso" "$root" >/dev/null 2>&1

entries=$(find "$root" -mindepth 1 -maxdepth 1 | wc -l)
echo "built ${iso} ($(wc -c < "$iso") bytes, ${entries} entries)"

# Prove the volume really carries a Joliet tree before anyone waits 90 minutes
# to find out. Windows reads F: through Joliet, and a Rock Ridge-only image is
# exactly the failure this script exists to prevent.
sh "${here}/check-joliet.sh" "$iso" || {
    echo "FAILED: ${iso} is not readable by Windows." >&2
    echo "        The build would hang at 'Waiting for IP...'." >&2
    exit 1
}

if [ "$upload" = "yes" ]; then
    command -v govc >/dev/null 2>&1 || { echo "--upload needs govc on PATH" >&2; exit 1; }
    : "${GOVC_DATASTORE:?GOVC_DATASTORE is required for --upload}"
    remote="packer-iso/$(basename "$iso")"
    echo "uploading to [${GOVC_DATASTORE}] ${remote}"
    govc datastore.mkdir "packer-iso" 2>/dev/null || true
    govc datastore.upload -ds "$GOVC_DATASTORE" "$iso" "$remote"
    echo "uploaded"
fi
