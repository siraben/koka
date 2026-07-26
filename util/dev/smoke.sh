#!/usr/bin/env bash
# Generated-C smoke test: the cheapest check that the whole pipeline
# (koka -> C -> cc -> executable) is intact.
#
# Usage: util/dev/smoke.sh [path-to-koka]
set -euo pipefail

KOKA="${1:-koka}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/smoke.kk" <<'EOF'
// exercises an effect handler, Perceus-managed lists, and the C backend
effect fun ask() : int

fun sum-list(xs : list<int>) : int
  xs.foldl(0, fn(a, b) a + b)

fun answer() : int
  with fun ask() 21
  sum-list([ask(), ask()])

fun main()
  println("smoke:" ++ answer().show)
EOF

out="$("$KOKA" -v0 -e "$tmp/smoke.kk" 2>&1)"
echo "$out"

if ! grep -q "^smoke:42$" <<<"$out"; then
  echo "smoke test FAILED: expected 'smoke:42'" >&2
  exit 1
fi

# The C really has to have been generated and compiled.
if ! "$KOKA" -v0 -c --showc "$tmp/smoke.kk" 2>/dev/null | grep -q "kk_std_core"; then
  echo "smoke test FAILED: --showc produced no recognizable generated C" >&2
  exit 1
fi

echo "smoke test OK"
