#!/usr/bin/env bash
# Orbit is no longer distributed from westsoever/orbit-releases.
# Source and release binaries now live in the main public repo: https://github.com/westsoever/orbit
# This file is kept only so old bookmarked "curl … | bash" commands keep working: it fetches the
# canonical installer and runs it in this process, so environment variables the caller set
# (ORBIT_VERSION, ORBIT_NO_START, …) are inherited unchanged.
set -eu

CANONICAL_URL="https://raw.githubusercontent.com/westsoever/orbit/main/scripts/install.sh"

echo "NOTICE: orbit-releases no longer hosts Orbit binaries." >&2
echo "        Installing from https://github.com/westsoever/orbit instead." >&2

script="$(curl -fsSL "$CANONICAL_URL")" || {
  echo "ERROR: could not fetch $CANONICAL_URL" >&2
  exit 1
}
exec bash -c "$script" install.sh "$@"
