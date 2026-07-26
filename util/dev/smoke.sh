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

# `with` binding a pattern rather than a plain name.  This aborted the compiler
# with an internal error, so it is worth a line here: the failure was a crash,
# not a diagnostic, and nothing else in the tree exercises the construct.
cat > "$tmp/withpat.kk" <<'EOF'
fun and-then( r : either<string,a>, next : (a) -> either<string,b> ) : either<string,b>
  match r
    Left(x)  -> Left(x)
    Right(v) -> next(v)

fun two() : either<string,int>
  with (a, b) <- Right((1,2)).and-then
  Right(a + b)

fun three() : either<string,int>
  with (a, b, c) <- Right((1,2,3)).and-then
  Right(a + b + c)

fun main()
  println(two().show ++ " " ++ three().show)
EOF

if ! "$KOKA" -v0 -e "$tmp/withpat.kk" 2>&1 | grep -q "^Right(3) Right(6)$"; then
  echo "smoke test FAILED: 'with' with a pattern binder" >&2
  "$KOKA" -v0 -e "$tmp/withpat.kk" 2>&1 | head -5 >&2
  exit 1
fi

# The C really has to have been generated and compiled.
if ! "$KOKA" -v0 -c --showc "$tmp/smoke.kk" 2>/dev/null | grep -q "kk_std_core"; then
  echo "smoke test FAILED: --showc produced no recognizable generated C" >&2
  exit 1
fi

echo "smoke test OK"
