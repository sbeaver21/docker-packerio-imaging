#!/bin/sh
# =============================================================================
#  check-joliet.sh
#
#      ./scripts/bootstrap/check-joliet.sh <file.iso>
#
#  Exits 0 when the image carries a Joliet supplementary volume descriptor,
#  non-zero otherwise. This is the property the Windows builds depend on: the
#  guest reads F: through Joliet, and a Rock Ridge-only image is invisible to it
#  ("The volume does not contain a recognized file system").
#
#  The check reads the ISO 9660 volume descriptor set directly instead of
#  asking a tool, because the obvious tool does not answer the question:
#  xorriso's -pvd_info prints only the primary descriptor, so grepping it for
#  "joliet" produces a false failure on a perfectly good image.
#
#  Descriptor set: sectors 16.., one 2048-byte descriptor per sector. Byte 0 is
#  the type - 1 primary, 2 supplementary, 255 terminator. A Joliet
#  supplementary descriptor carries an escape sequence at offset 88: %/@, %/C
#  or %/E (UCS-2 levels 1, 2 and 3).
# =============================================================================
set -eu

img="${1:?usage: check-joliet.sh <file.iso>}"
[ -f "$img" ] || { echo "no such file: ${img}" >&2; exit 2; }

sector=16
while [ "$sector" -lt 32 ]; do
    offset=$((sector * 2048))
    type=$(dd if="$img" bs=1 skip="$offset" count=1 2>/dev/null \
        | od -An -tu1 | tr -d ' \n')

    # Short read or terminator: no further descriptors to inspect.
    [ -z "$type" ] && break
    [ "$type" = "255" ] && break

    if [ "$type" = "2" ]; then
        escape=$(dd if="$img" bs=1 skip=$((offset + 88)) count=3 2>/dev/null)
        case "$escape" in
            '%/@'|'%/C'|'%/E')
                echo "joliet: present (sector ${sector}, escape ${escape})"
                exit 0
                ;;
        esac
    fi

    sector=$((sector + 1))
done

echo "joliet: ABSENT - Windows cannot read this volume" >&2
exit 1
