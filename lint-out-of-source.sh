#!/bin/bash
# lint-out-of-source.sh — guard the out-of-source / read-only-SOURCES invariant.
#
# Every bits recipe must build from its private rsync'd copy and treat the shared
# SOURCES tree as read-only. This catches the two ways a recipe breaks that:
#
#   1. Pointing cmake at "$SOURCEDIR" instead of the framework indirection
#      (-S "$BITS_CMAKE_SRC" -B "$BITS_CMAKE_BUILD"). Such a recipe configures
#      from SOURCES, so any in-tree write (Davix bundled-curl, codegen) lands on
#      the shared tree.
#   2. Writing into "$SOURCEDIR" directly (sed -i / patch / tar -C / redirect /
#      copy whose destination is under SOURCEDIR). Reads (cp FROM SOURCEDIR into
#      INSTALLROOT, rsync FROM SOURCEDIR) are fine and are not flagged.
#
# Usage: lint-out-of-source.sh [recipe-dir ...]   (default: current directory)
# Exit non-zero if any violation is found. Wire into CI.

set -u
dirs=("${@:-.}")
rc=0

# Scan only the recipe body (after the first '---'); the YAML header isn't shell.
body() { awk 'p{print} /^---[[:space:]]*$/{p=1}' "$1"; }

while IFS= read -r -d '' f; do
  b="$(body "$f")"
  # strip comments for the write checks (comments may legitimately mention these)
  code="$(printf '%s\n' "$b" | sed -E 's/[[:space:]]*#.*$//')"

  # 1. cmake pointed at $SOURCEDIR
  if printf '%s\n' "$code" | grep -qE 'cmake[[:space:]]+("?\$\{?SOURCEDIR|.*-S[[:space:]]+"?\$\{?SOURCEDIR)'; then
    echo "ERROR  $f: cmake reads \$SOURCEDIR — use -S \"\$BITS_CMAKE_SRC\" -B \"\$BITS_CMAKE_BUILD\""
    rc=1
  fi

  # 2. in-place writes into $SOURCEDIR
  if printf '%s\n' "$code" | grep -qE 'sed -i[^|]*\$\{?SOURCEDIR'; then
    echo "ERROR  $f: 'sed -i' edits \$SOURCEDIR — patch the rsync'd copy instead"
    rc=1
  fi
  if printf '%s\n' "$code" | grep -qE '(tar[^|]*-C[[:space:]]+"?\$\{?SOURCEDIR|>[[:space:]]*"?\$\{?SOURCEDIR|-DDESTINATION=[^[:space:]]*\$\{?SOURCEDIR)'; then
    echo "ERROR  $f: writes output under \$SOURCEDIR — write under the copy (\$PWD / \$BITS_CMAKE_SRC)"
    rc=1
  fi
  # copy/move whose DESTINATION (last token) is under $SOURCEDIR
  if printf '%s\n' "$code" | grep -qE '\b(cp|mv|rsync)\b[^|]*[[:space:]]"?\$\{?SOURCEDIR[^"[:space:]]*"?[[:space:]]*(&&|\||;|$)'; then
    echo "ERROR  $f: copies INTO \$SOURCEDIR — destination must be the copy or INSTALLROOT"
    rc=1
  fi
done < <(find "${dirs[@]}" -name '*.sh' -type f -print0 2>/dev/null)

if [ "$rc" -eq 0 ]; then
  echo "lint-out-of-source: OK — no recipe builds from or writes to SOURCES"
fi
exit "$rc"
