#!/usr/bin/env bash
#
# Download the pinned Terraform release into tools/terraform.
#
# Terraform is not committed: it is a platform-specific binary of ~30 MB, and a
# binary in git is either stale or enormous. This fetches the exact release in
# terraform.lock, verifies the SHA-256 pinned there, and unpacks it beside the
# repository so `tools/terraform/terraform` is the documented command.
#
# A digest mismatch stops the fetch. That is the point of the lock: a run that
# used a different Terraform than the one recorded here is not reproducible, and
# nothing else would show the difference.
#
#   ./scripts/bootstrap/fetch-terraform.sh
#   ./scripts/bootstrap/fetch-terraform.sh --destination /usr/local/bin
#
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOCK="$REPO_ROOT/scripts/bootstrap/terraform.lock"
DESTINATION=""

die() { printf 'fetch-terraform: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --destination)
            [ $# -ge 2 ] || die "--destination needs a path"
            DESTINATION=$2
            shift 2
            ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -f "$LOCK" ] || die "no lock file at $LOCK"

# The lock is a flat, greppable file so both this script and the PowerShell one
# read it without a parser: `version <v>` then `<platform> <sha256>`.
VERSION=$(awk '$1 == "version" { print $2; exit }' "$LOCK")
[ -n "$VERSION" ] || die "terraform.lock records no version"

# Git Bash and Cygwin run this script but need the Windows build, so they map to
# the windows_* artifacts and to a terraform.exe target.
EXE=""
case "$(uname -s)" in
    Linux)                OS=linux ;;
    Darwin)               OS=darwin ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows; EXE=".exe" ;;
    *)                    die "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *)             die "unsupported architecture: $(uname -m)" ;;
esac

PLATFORM="${OS}_${ARCH}"
EXPECTED=$(awk -v p="$PLATFORM" '$1 == p { print $2; exit }' "$LOCK")
[ -n "$EXPECTED" ] || die "terraform.lock has no digest for $PLATFORM"

[ -n "$DESTINATION" ] || DESTINATION="$REPO_ROOT/tools/terraform"
TARGET="$DESTINATION/terraform${EXE}"

# Already at the pinned version: no download, no network.
if [ -x "$TARGET" ]; then
    if "$TARGET" version 2>/dev/null | head -n 1 | grep -qx "Terraform v$VERSION"; then
        echo "terraform $VERSION already present at $TARGET"
        exit 0
    fi
fi

ARCHIVE="terraform_${VERSION}_${PLATFORM}.zip"
URL="https://releases.hashicorp.com/terraform/${VERSION}/${ARCHIVE}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/$ARCHIVE"

echo "downloading $ARCHIVE"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$ZIP" "$URL" || die "download failed: $URL"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$ZIP" "$URL" || die "download failed: $URL"
else
    die "neither curl nor wget is available"
fi

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$ZIP" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
else
    die "no sha256sum or shasum available to verify the download"
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
    cat >&2 <<EOF
digest mismatch for $ARCHIVE
  expected $EXPECTED
  actual   $ACTUAL
Refusing to install. Update terraform.lock only after checking the digest
against https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_SHA256SUMS
EOF
    exit 1
fi

mkdir -p "$DESTINATION"
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$ZIP" -d "$DESTINATION"
else
    die "unzip is not installed"
fi
# No executable bit on Windows; chmod would be a no-op the shell reports as fine.
[ -n "$EXE" ] || chmod +x "$TARGET"

echo "installed $DESTINATION"
echo "  $("$TARGET" version | head -n 1)"
echo "  sha256 $ACTUAL"
