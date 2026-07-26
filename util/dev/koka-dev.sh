#!/usr/bin/env bash
# Run the cabal-built compiler from the working tree.
#
# The installed compiler finds the standard library and kklib under
# <bindir>/../share/koka/<version>.  A cabal build has no such layout, so point
# it at the source tree instead: `lib/` and `kklib/` at the repository root are
# exactly what a share directory contains.
#
# Usage:  util/dev/koka-dev.sh [koka arguments...]
# Must be run inside `nix develop` (or with ghc/cabal/cc on PATH).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bin="${KOKA_DEV_BIN:-}"
if [ -z "$bin" ]; then
  bin="$(cd "$here" && cabal list-bin --project-file=cabal.project.plain exe:koka-plain)"
fi

exec "$bin" --sharedir="$here" "$@"
