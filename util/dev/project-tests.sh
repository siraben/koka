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
  *)   KOKA="$(command -v "$KOKA")" ;;
esac

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
group(){ printf '\n== %s\n' "$1"; }

# run a command in a directory without losing the pass/fail counters to a subshell
run_in() { local d="$1"; shift; ( cd "$d" && "$@" ); }

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

# a source implementation change keeps the *directory* (incremental build) but
# must produce new behaviour
cat > "$lib/src/greet/hello.kk" <<'EOF'
pub fun greeting(name : string) : string
  "HELLO, " ++ name
EOF
assert_contains "implementation change takes effect" "HELLO, world" run_in "$app" "$KOKA" run -v0

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

# a corrupt cache is discarded, not half-used
victim="$(ls "$builddir" | head -1)"
printf 'this is not a cache key\n' > "$builddir/$victim/cache-key.txt"
assert_ok "corrupt cache is discarded and rebuilt" run_in "$app" "$KOKA" build -v0

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

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
