#!/bin/sh
# ---------------------------------------------------------------------------
# build-scripts-isos.sh
#
# Builds the per-edition "scripts" ISOs that become the F: drive inside the
# Windows builds, and leaves them in builds/windows/packer-iso/.
#
# WHY THIS EXISTS
# ---------------
# On Linux, Packer creates `cd_files` with xorriso in Rock Ridge mode. Windows
# cannot read that volume ("The volume does not contain a recognized file
# system"), so every F:\... first-logon command fails and the build hangs at
# "Waiting for IP". The Windows-hosted Packer uses its own Joliet writer, which
# is why the same templates work there.
#
# This script builds the same payload with Joliet (-J) so Windows can read it.
# Attach the result through iso_paths instead of cd_files.
#
# WHEN TO RE-RUN
# --------------
# Any time anything under builds/windows/files/ or the per-edition
# <edition>/temp-network.ps1 changes. Then re-upload the ISOs to the datastore
# (packer-iso/ folder) - see README-WINDOWS-ISO.md.
# ---------------------------------------------------------------------------
set -e

ROOT=${1:-/workspace}
FILES="$ROOT/builds/windows/files"
OUT="$ROOT/builds/windows/packer-iso"
mkdir -p "$OUT"

build_one() {
  ver="$1"; ed="$2"
  proj="$ROOT/builds/windows/server/${ver}-${ed}"
  root="/tmp/cdroot-${ver}-${ed}"
  iso="$OUT/win${ver}-${ed}-scripts.iso"

  rm -rf "$root"; mkdir -p "$root"

  # edition specific staging script (temp-network.ps1 lives here)
  [ -d "$proj/$ed" ] && cp -a "$proj/$ed/." "$root/"

  # shared flat payload (scripts, whl, msi) - mirror builds/windows/files/*
  for f in "$FILES"/*.ps1 "$FILES"/*.whl "$FILES"/*.msi; do
    case "$f" in *.bak*) continue ;; esac
    [ -f "$f" ] && cp -a "$f" "$root/"
  done

  # staging folders consumed by win-init.ps1 ($StageFolder = CD, Temp)
  [ -d "$FILES/CD" ]   && cp -a "$FILES/CD"   "$root/CD"
  [ -d "$FILES/Temp" ] && cp -a "$FILES/Temp" "$root/Temp"

  rm -f "$iso"
  xorriso -as mkisofs -J -joliet-long -R -V PACKER_CD -o "$iso" "$root" >/dev/null 2>&1
  echo "built $(basename "$iso") : $(stat -c %s "$iso") bytes, $(ls "$root" | wc -l) entries"
}

for ed in standard-core standard-dexp datacenter-core datacenter-dexp; do
  build_one 2022 "$ed"
done
for ed in standard-core standard-dexp datacenter-core datacenter-dexp; do
  build_one 2025 "$ed"
done

echo
echo "ISOs written to $OUT"
ls -la "$OUT"
