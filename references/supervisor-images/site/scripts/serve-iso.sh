#!/bin/bash 
# serve-iso.sh
#
# Bash script to serve ISOs from the project's iso/ directory over HTTP
# so that the vSphere Supervisor cluster can access them for image import.
#
# Usage:
#   ./scripts/serve-iso.sh [port]
#
# Examples:
#   ./scripts/serve-iso.sh
#   ./scripts/serve-iso.sh 9090
#
# To test locally before using in the Supervisor:
#   curl http://localhost:8080/
#   curl -O http://localhost:8080/SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO
#
# Prerequisites:
#   - Python 3 must be available on the PATH
#
# Notes:
#   - This script starts a simple Python HTTP server on port 8080 (or custom port)
#   - It serves files from the project's iso/ directory
#   - Press Ctrl+C to stop the server when done

set -euo pipefail

PORT="${1:-8080}"

# Determine script and project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Four levels up: scripts/ -> site/ -> supervisor-images/ -> references/ -> root.
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ISO_DIR="$PROJECT_ROOT/iso"

# Verify ISO directory exists
if [ ! -d "$ISO_DIR" ]; then
    echo "ERROR: ISO directory not found: $ISO_DIR" >&2
    exit 1
fi

echo "=========================================="
echo "  vSphere Supervisor ISO File Server"
echo "=========================================="
echo ""
echo "ISO Directory: $ISO_DIR"
echo ""
echo "Available ISO files:"
while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    size=$(numfmt --to=iec --suffix=B "$(stat --printf="%s" "$file")" 2>/dev/null || ls -lh "$file" | awk '{print $5}')
    echo "  - $filename ($size)"
done < <(find "$ISO_DIR" -maxdepth 1 -name '*.iso' -print0)
echo ""
echo "Server URL: http://localhost:$PORT/"
echo ""

# Find local IP addresses
echo "Local IP addresses for remote access:"
ip addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | while read -r ip; do
    echo "  http://$ip:$PORT/"
done
echo ""

# Show example import_source_url values
echo "Example import_source_url usage:"
ip addr show 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | while read -r ip; do
    for iso in "$ISO_DIR"/*.iso; do
        echo "  import_source_url = \"http://$ip:$PORT/$(basename "$iso")\""
    done
done
echo ""

echo "Starting HTTP server... Press Ctrl+C to stop."
echo "=========================================="

# Change to ISO directory and start Python HTTP server
cd "$ISO_DIR"
python3 -m http.server "$PORT" || python -m http.server "$PORT"
