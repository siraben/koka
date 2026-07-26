#!/usr/bin/env bash
# Tests for the project tooling: koka init/fetch/build/run/test/clean,
# lockfile determinism, and build-cache invalidation.
#
# Everything runs against a local git repository, so the suite needs no
# network.
#
# Usage: util/dev/project-tests.sh [path-to-koka]
set -uo pipefail

KOKA="${1:-koka}"
# The tests cd into temporary project directories, so the compiler must be
# addressed absolutely.
case "$KOKA" in
  */*) KOKA="$(cd "$(dirname "$KOKA")" && pwd)/$(basename "$KOKA")" ;;
  *)   KOKA="$(command -v "$KOKA" || true)" ;;
esac
# Without this, an unset compiler turned every assertion into a failure that
# looked like a bug in the tooling rather than a bug in how the suite was run.
if [ -z "$KOKA" ] || [ ! -x "$KOKA" ]; then
  echo "no koka compiler found; pass one as the first argument" >&2
  exit 2
fi

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
group(){ printf '\n== %s\n' "$1"; }

# Run a command in a directory without losing the pass/fail counters to a
# subshell.  `cd || exit 99` rather than `cd &&`: a failed cd otherwise looked
# exactly like a failed command, so every `assert_fail` would have passed
# without the compiler being run at all.
run_in() { local d="$1"; shift; ( cd "$d" || exit 99; "$@" ); }

# assert_ok <name> <command...>
assert_ok() {
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then ok "$name"; else bad "$name" "$(tail -3 <<<"$out")"; fi
}

# assert_fail <name> <command...>
assert_fail() {
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then bad "$name" "expected failure, succeeded"; else ok "$name"; fi
}

# assert_contains <name> <needle> <command...>
assert_contains() {
  local name="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if grep -qF -- "$needle" <<<"$out"; then ok "$name"
  else bad "$name" "missing '$needle' in: $(tail -3 <<<"$out")"; fi
}

# ---------------------------------------------------------------------------
group "koka init"

app="$root/app"
mkdir -p "$app"
( cd "$app" && "$KOKA" init >/dev/null 2>&1 )
[ -f "$app/koka.toml" ]        && ok "creates koka.toml"        || bad "creates koka.toml"
[ -f "$app/src/main.kk" ]      && ok "creates src/main.kk"      || bad "creates src/main.kk"
[ -d "$app/test" ]             && ok "creates test/"            || bad "creates test/"
assert_fail "refuses to overwrite an existing project" run_in "$app" "$KOKA" init

# ---------------------------------------------------------------------------
group "a path dependency"

lib="$root/greet"
mkdir -p "$lib/src/greet"
cat > "$lib/koka.toml" <<'EOF'
[package]
name = "greet"
version = "0.1.0"

[sources]
directories = ["src"]
EOF
cat > "$lib/src/greet/hello.kk" <<'EOF'
pub fun greeting(name : string) : string
  "hello, " ++ name
EOF

cat > "$app/koka.toml" <<EOF
[package]
name = "app"
version = "0.1.0"
koka = ">=3.2,<4"

[sources]
directories = ["src"]

[dependencies]
greet = { path = "../greet" }

[targets.app]
main = "src/main.kk"

[targets.test]
directories = ["test"]
EOF
cat > "$app/src/main.kk" <<'EOF'
import greet/hello

fun main()
  println(greeting("world"))
EOF

assert_ok "fetch resolves the path dependency" run_in "$app" "$KOKA" fetch -v0
[ -f "$app/koka.lock" ] && ok "fetch writes koka.lock" || bad "fetch writes koka.lock"
grep -q 'kind = "path"' "$app/koka.lock" && ok "lockfile records the dependency kind" \
                                          || bad "lockfile records the dependency kind"
grep -q 'checksum = "sha256:' "$app/koka.lock" && ok "lockfile records a content checksum" \
                                                || bad "lockfile records a content checksum"
grep -qi 'time\|date\|20[0-9][0-9]-' "$app/koka.lock" && bad "lockfile has no timestamps" \
                                                       || ok "lockfile has no timestamps"

assert_contains "run executes the app" "hello, world" run_in "$app" "$KOKA" run -v0

# determinism: regenerating from unchanged inputs is byte-identical
cp "$app/koka.lock" "$root/lock.1"
( cd "$app" && "$KOKA" fetch -v0 >/dev/null 2>&1 )
cmp -s "$root/lock.1" "$app/koka.lock" && ok "lockfile regeneration is byte-identical" \
                                        || bad "lockfile regeneration is byte-identical"

# ---------------------------------------------------------------------------
group "--locked"

assert_ok "locked build with an up-to-date lockfile" run_in "$app" "$KOKA" build --locked -v0

cat >> "$app/koka.toml" <<'EOF'

[dependencies.extra]
path = "../greet"
EOF
assert_fail "locked build rejects a new dependency" run_in "$app" "$KOKA" fetch --locked -v0
# restore
python3 - "$app/koka.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p,"w").write(s.split("\n[dependencies.extra]")[0])
PY
assert_ok "manifest restored" run_in "$app" "$KOKA" fetch --locked -v0

# a corrupt lockfile must be reported, not ignored
cp "$app/koka.lock" "$root/lock.good"
printf 'version = "not a number"\n' > "$app/koka.lock"
assert_contains "corrupt lockfile is reported" "corrupt" run_in "$app" "$KOKA" build -v0
cp "$root/lock.good" "$app/koka.lock"

# ---------------------------------------------------------------------------
group "koka test"

cat > "$app/test/greet-test.kk" <<'EOF'
import greet/hello

fun main()
  if greeting("a") != "hello, a" then
    throw("greeting is wrong")
EOF
assert_contains "passing tests are reported" "2 passed, 0 failed" run_in "$app" "$KOKA" test -v0

cat > "$app/test/failing-test.kk" <<'EOF'
extern import
  c header-end-file "exit-inline.c"

extern xexit(code : int32) : ()
  c "kk_test_exit"

fun main()
  println("deliberate failure")
  xexit(1.int32)
EOF
cat > "$app/test/exit-inline.c" <<'EOF'
#include <stdlib.h>
static kk_unit_t kk_test_exit(int32_t code, kk_context_t* _ctx) { exit((int)code); }
EOF
assert_fail "a test that exits non-zero fails the run" run_in "$app" "$KOKA" test -v0
assert_contains "the failing test is listed" "failed: test/failing-test.kk" run_in "$app" "$KOKA" test -v0
rm "$app/test/failing-test.kk"

# an uncaught exception exits 0 in koka, so the runner must catch it separately
cat > "$app/test/crashing-test.kk" <<'EOF'
fun main()
  throw("this test is meant to crash")
EOF
assert_fail "an uncaught exception fails the run" run_in "$app" "$KOKA" test -v0
rm "$app/test/crashing-test.kk"

cat > "$app/test/_support.kk" <<'EOF'
pub fun helper() : int
  1
EOF
assert_contains "underscore files are not run as tests" "2 passed, 0 failed" run_in "$app" "$KOKA" test -v0

# ---------------------------------------------------------------------------
group "build cache"

builddir="$app/.koka/build"
key_of() { ls "$builddir" | sort | tr '\n' ' '; }

( cd "$app" && "$KOKA" build -v0 >/dev/null 2>&1 )
before="$(key_of)"

# a no-op rebuild must not change the cache key and must be fast
start=$(date +%s%N)
( cd "$app" && "$KOKA" build -v0 >/dev/null 2>&1 )
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$(key_of)" = "$before" ] && ok "no-op rebuild reuses the cache key" \
                             || bad "no-op rebuild reuses the cache key"
[ "$elapsed" -lt 5000 ] && ok "no-op rebuild is fast (${elapsed}ms)" \
                         || bad "no-op rebuild is fast" "took ${elapsed}ms"

# A source implementation change keeps the *directory* (incremental build) but
# must produce new behaviour.  Both halves are asserted: with the source hash
# in the directory name, every edit silently started a fresh full build tree
# and nothing ever collected the old ones.
cat > "$lib/src/greet/hello.kk" <<'EOF'
pub fun greeting(name : string) : string
  "HELLO, " ++ name
EOF
assert_contains "implementation change takes effect" "HELLO, world" run_in "$app" "$KOKA" run -v0

# Editing the project's *own* sources must reuse the build directory: that is
# what leaves the work to Koka's per-module incremental compilation.  (A path
# dependency is different -- its checksum is part of the lockfile, so editing
# one does select a new directory.)
( cd "$app" && "$KOKA" build -v0 >/dev/null 2>&1 )
before="$(key_of)"
cat >> "$app/src/main.kk" <<'EOF'

fun unused-helper() : int
  7
EOF
assert_ok "an edit to the project's own sources builds" run_in "$app" "$KOKA" build -v0
[ "$(key_of)" = "$before" ] && ok "an edit to own sources reuses the build directory" \
                            || bad "an edit to own sources reuses the build directory" \
                                   "was [$before] now [$(key_of)]"

# an exported type change must be picked up across the dependency boundary
cat > "$lib/src/greet/hello.kk" <<'EOF'
pub fun greeting(name : string) : int
  name.count
EOF
cat > "$app/src/main.kk" <<'EOF'
import greet/hello

fun main()
  val s : string = greeting("world")
  println(s)
EOF
assert_fail "exported type change is detected" run_in "$app" "$KOKA" build -v0

# an exported effect change must be picked up too
cat > "$lib/src/greet/hello.kk" <<'EOF'
pub fun greeting(name : string) : console string
  println("side effect")
  "hello, " ++ name
EOF
cat > "$app/src/main.kk" <<'EOF'
import greet/hello

fun main()
  println(greeting("world"))
EOF
assert_ok "exported effect change still builds where allowed" run_in "$app" "$KOKA" build -v0
cat > "$app/src/pure-use.kk" <<'EOF'
import greet/hello

pub fun pure-greeting(name : string) : total string
  greeting(name)
EOF
cat > "$app/src/main.kk" <<'EOF'
import pure-use

fun main()
  println(pure-greeting("world"))
EOF
assert_fail "exported effect change is detected in pure context" run_in "$app" "$KOKA" build -v0
rm "$app/src/pure-use.kk"

# restore
cat > "$lib/src/greet/hello.kk" <<'EOF'
pub fun greeting(name : string) : string
  "hello, " ++ name
EOF
cat > "$app/src/main.kk" <<'EOF'
import greet/hello

fun main()
  println(greeting("world"))
EOF
( cd "$app" && "$KOKA" build -v0 >/dev/null 2>&1 )

# build profile is part of the cache key
before="$(key_of)"
( cd "$app" && "$KOKA" build --release -v0 >/dev/null 2>&1 )
[ "$(key_of)" != "$before" ] && ok "--release selects a different cache entry" \
                              || bad "--release selects a different cache entry"

# A corrupt cache is discarded, not half-used.  Exit status alone was not
# enough: a build that ignored the corrupt stamp entirely and reused the stale
# artifacts would also have exited 0.
# A fresh project, so there is exactly one cache directory and the one being
# corrupted is unambiguously the one the next build will use.  (Picking
# `ls | head -1` after a --release build selected whichever name sorted first,
# which is not necessarily the debug entry.)
cor="$root/corrupt"
mkdir -p "$cor"
( cd "$cor" && "$KOKA" init -v0 >/dev/null 2>&1 )
( cd "$cor" && "$KOKA" build -v0 >/dev/null 2>&1 )
cordir="$cor/.koka/build"
victim="$(ls "$cordir" | head -1)"
printf 'this is not a cache key\n' > "$cordir/$victim/cache-key.txt"
assert_ok "corrupt cache is discarded and rebuilt" run_in "$cor" "$KOKA" build -v0
if grep -q 'this is not a cache key' "$cordir/$victim/cache-key.txt" 2>/dev/null; then
  bad "the corrupt stamp was replaced, not left in place" \
      "$(head -1 "$cordir/$victim/cache-key.txt")"
else
  ok "the corrupt stamp was replaced, not left in place"
fi

# ---------------------------------------------------------------------------
group "koka clean"

( cd "$app" && "$KOKA" clean >/dev/null 2>&1 )
[ -z "$(ls -A "$builddir" 2>/dev/null)" ] && ok "clean removes build artifacts" \
                                           || bad "clean removes build artifacts"
[ -f "$app/koka.lock" ] && ok "clean keeps the lockfile" || bad "clean keeps the lockfile"

# ---------------------------------------------------------------------------
group "a git dependency pinned to an exact commit"

gitlib="$root/gitlib"
mkdir -p "$gitlib/src/pinned"
cat > "$gitlib/koka.toml" <<'EOF'
[package]
name = "pinned"
version = "0.1.0"

[sources]
directories = ["src"]
EOF
cat > "$gitlib/src/pinned/value.kk" <<'EOF'
pub fun answer() : int
  42
EOF
(
  cd "$gitlib"
  git init -q .
  git config user.email t@example.com
  git config user.name test
  git add -A && git commit -q -m "v1"
)
rev1="$(git -C "$gitlib" rev-parse HEAD)"

# a second commit that the pin must NOT pick up
cat > "$gitlib/src/pinned/value.kk" <<'EOF'
pub fun answer() : int
  99
EOF
( cd "$gitlib" && git add -A && git commit -q -m "v2" )
rev2="$(git -C "$gitlib" rev-parse HEAD)"

gitapp="$root/gitapp"
mkdir -p "$gitapp/src"
cat > "$gitapp/koka.toml" <<EOF
[package]
name = "gitapp"
version = "0.1.0"

[sources]
directories = ["src"]

[dependencies]
pinned = { git = "file://$gitlib", rev = "$rev1" }

[targets.app]
main = "src/main.kk"
EOF
cat > "$gitapp/src/main.kk" <<'EOF'
import pinned/value

fun main()
  println("answer=" ++ answer().show)
EOF

assert_ok "fetch clones the pinned commit" run_in "$gitapp" "$KOKA" fetch -v0
grep -q "$rev1" "$gitapp/koka.lock" && ok "lockfile records the exact commit" \
                                     || bad "lockfile records the exact commit"
assert_contains "the pinned commit is what gets built" "answer=42" run_in "$gitapp" "$KOKA" run -v0

# a branch or tag instead of a full sha must be rejected outright
sed -i "s/rev = \"$rev1\"/rev = \"main\"/" "$gitapp/koka.toml"
assert_contains "a non-pinned rev is rejected" "40-character" run_in "$gitapp" "$KOKA" fetch -v0
sed -i "s/rev = \"main\"/rev = \"$rev2\"/" "$gitapp/koka.toml"

# changing the pin selects a different cache entry and different behaviour
assert_contains "changing the pin changes the build" "answer=99" run_in "$gitapp" "$KOKA" run -v0
grep -q "$rev2" "$gitapp/koka.lock" && ok "lockfile follows the new pin" \
                                     || bad "lockfile follows the new pin"

# ---------------------------------------------------------------------------
group "error reporting"

broken="$root/broken"
mkdir -p "$broken"
cat > "$broken/koka.toml" <<'EOF'
[package]
version = "0.1.0"
EOF
assert_contains "a missing package.name is reported" "package.name" run_in "$broken" "$KOKA" build -v0

cat > "$broken/koka.toml" <<'EOF'
[package]
name = "broken"
version = "0.1.0"
koka = ">=99"
EOF
assert_contains "an unsatisfiable compiler constraint is reported" "requires koka" run_in "$broken" "$KOKA" build -v0

nowhere="$root/nowhere"
mkdir -p "$nowhere"
assert_contains "a missing manifest is reported" "koka.toml" run_in "$nowhere" "$KOKA" build -v0

# A dependency of a dependency that moves must be caught by --locked.  Only the
# root manifest's direct dependencies were compared, so this drifted silently:
# the new package was fetched, built and linked, and the lockfile still claimed
# the old graph.
group "--locked covers the whole graph"

tl="$root/translib"; tm="$root/transmid"; ta="$root/transapp"
mkdir -p "$tl/src/tl" "$tm/src/tm" "$ta/src"
cat > "$tl/koka.toml" <<'EOF'
[package]
name = "tl"
version = "0.1.0"
[sources]
directories = ["src"]
EOF
printf 'pub fun v() : int
  1
' > "$tl/src/tl/v.kk"

cat > "$tm/koka.toml" <<'EOF'
[package]
name = "tm"
version = "0.1.0"
[sources]
directories = ["src"]
[dependencies]
tl = { path = "../translib" }
EOF
printf 'import tl/v
pub fun w() : int
  v()
' > "$tm/src/tm/w.kk"

cat > "$ta/koka.toml" <<'EOF'
[package]
name = "ta"
version = "0.1.0"
[sources]
directories = ["src"]
[dependencies]
tm = { path = "../transmid" }
[targets.app]
main = "src/main.kk"
EOF
printf 'import tm/w
fun main()
  println("w=" ++ w().show)
' > "$ta/src/main.kk"

assert_ok "a transitive graph resolves and locks" run_in "$ta" "$KOKA" fetch -v0

# Drop the *transitive* package's entry from the lockfile, leaving every
# manifest and every remaining checksum untouched.  Only the root manifest's
# direct dependencies were compared, so this passed --locked: `tl` was resolved
# and linked while the lockfile did not mention it at all.
cp "$ta/koka.lock" "$ta/koka.lock.good"
python3 - "$ta/koka.lock" <<'PYDROP'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n\[packages\.tl\]\n(?:(?!\n\[).)*', '\n', s, flags=re.S)
open(p, 'w').write(s)
PYDROP
if grep -q '\[packages\.tl\]' "$ta/koka.lock"; then
  bad "the transitive entry was actually removed from the lockfile"
else
  ok "the transitive entry was actually removed from the lockfile"
fi
assert_contains "--locked refuses a lockfile missing a transitive package" \
                "does not describe this build" run_in "$ta" "$KOKA" build --locked -v0
cp "$ta/koka.lock.good" "$ta/koka.lock"
assert_ok "and the intact lockfile still satisfies --locked" run_in "$ta" "$KOKA" build --locked -v0

# Deleting a checksum line is quieter than corrupting one, so it was the
# better attack: verification simply did not run for that package.
python3 - "$ta/koka.lock" <<'PYSTRIP'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\nchecksum = "sha256:[0-9a-f]{64}"', '', s, count=1)
open(p, 'w').write(s)
PYSTRIP
assert_contains "--locked refuses a lock entry with no checksum" \
                "no checksum recorded" run_in "$ta" "$KOKA" build --locked -v0
cp "$ta/koka.lock.good" "$ta/koka.lock"

# ---------------------------------------------------------------------------
group "malformed input is refused, not obeyed"

# A dependency name becomes a directory under .koka/deps, and fetching deletes
# that directory first -- so a name that escapes the project would delete
# whatever it pointed at.
traversal="$root/traversal"
mkdir -p "$traversal/src/t"
cat > "$traversal/koka.toml" <<'EOF'
[package]
name = "traversal"
version = "0.1.0"

[sources]
directories = ["src"]

[dependencies]
"../../../../tmp/koka-traversal-victim" = { path = "../lib" }
EOF
assert_contains "a dependency name that escapes the project is refused" \
                "is not allowed" run_in "$traversal" "$KOKA" build -v0

# `version = _` used to reach `read ""`, which is partial: the process died
# with an exception instead of reporting a parse error.
badlock="$root/badlock"
mkdir -p "$badlock/src/b"
cat > "$badlock/koka.toml" <<'EOF'
[package]
name = "badlock"
version = "0.1.0"

[sources]
directories = ["src"]
EOF
printf 'version = _\n' > "$badlock/koka.lock"
out="$(cd "$badlock" && "$KOKA" build -v0 2>&1)"
case "$out" in
  *"Prelude.read"*|*"no parse"*)
    bad "an underscore-only integer is a parse error, not a crash" "$out" ;;
  *)
    ok "an underscore-only integer is a parse error, not a crash" ;;
esac

# A checksum of the wrong type silently disabled verification altogether.
cat > "$badlock/koka.lock" <<'EOF'
version = 1
root = "badlock"
koka = "3.2.7"

[packages.badlock]
kind = "path"
path = "."
checksum = 0
EOF
assert_contains "a non-string checksum is reported as corruption" \
                "checksum" run_in "$badlock" "$KOKA" build -v0

# A duplicate key silently kept the first binding, so a manifest could say one
# thing and mean another.
cat > "$badlock/koka.toml" <<'EOF'
[package]
name = "safe"
name = "other"
version = "0.1.0"
EOF
assert_contains "a duplicate key is refused" "duplicate key" run_in "$badlock" "$KOKA" build -v0

# A non-numeric constraint operand parsed as version 0, so it was satisfied by
# every compiler rather than reported as malformed.
cat > "$badlock/koka.toml" <<'EOF'
[package]
name = "badlock"
version = "0.1.0"
koka = ">=banana"
EOF
assert_contains "a malformed version constraint is refused" \
                "not a version" run_in "$badlock" "$KOKA" build -v0

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
