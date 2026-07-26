#!/usr/bin/env bash
# Minimal benchmark harness.
#
# Measures, for one or more Koka programs:
#   * clean build time      (no cached modules for the program)
#   * no-op rebuild time    (everything up to date)
#   * runtime               (executing the built program)
#   * peak resident memory  (of the program run, where /usr/bin/time supports it)
#
# and records the compiler's own --stats=json alongside, so generated-C size and
# executable size are captured in the same record.
#
# Output is one JSON object per program on stdout (JSON lines), so results can
# be appended to a file and diffed or plotted over time.
#
# Usage:
#   util/dev/bench.sh [-k koka] [-n runs] [-o results.jsonl] program.kk [more.kk ...]
#
# With no programs given, benchmarks a small built-in set from samples/.
set -euo pipefail

KOKA="koka"
RUNS=3
OUT=""

while getopts "k:n:o:h" opt; do
  case "$opt" in
    k) KOKA="$OPTARG" ;;
    n) RUNS="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

case "$KOKA" in
  */*) KOKA="$(cd "$(dirname "$KOKA")" && pwd)/$(basename "$KOKA")" ;;
  *)   KOKA="$(command -v "$KOKA")" ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

programs=("$@")
if [ ${#programs[@]} -eq 0 ]; then
  programs=(
    "$here/samples/basic/fibonacci.kk"
    "$here/samples/handlers/basic.kk"
  )
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# milliseconds since epoch, portable enough for Linux and macOS with coreutils
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# median of the numbers on stdin
median() { sort -n | awk '{a[NR]=$1} END{ if (NR==0) print 0; else if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'; }

emit() { if [ -n "$OUT" ]; then printf '%s\n' "$1" | tee -a "$OUT"; else printf '%s\n' "$1"; fi; }

for prog in "${programs[@]}"; do
  if [ ! -f "$prog" ]; then
    echo "bench: no such program: $prog" >&2
    continue
  fi
  name="$(basename "$prog" .kk)"
  builddir="$work/$name"
  rm -rf "$builddir"

  # ---- clean build -------------------------------------------------------
  clean_times=""
  for _ in $(seq 1 "$RUNS"); do
    rm -rf "$builddir"
    t0=$(now_ms)
    "$KOKA" -c -v0 --builddir="$builddir" --stats-file="$work/$name.stats.json" \
            --stats=json "$prog" >/dev/null 2>&1 || {
      echo "bench: failed to build $prog" >&2; continue 2; }
    t1=$(now_ms)
    clean_times="$clean_times$((t1 - t0))
"
  done
  clean_ms="$(printf '%s' "$clean_times" | median)"

  # ---- no-op rebuild -----------------------------------------------------
  noop_times=""
  for _ in $(seq 1 "$RUNS"); do
    t0=$(now_ms)
    "$KOKA" -c -v0 --builddir="$builddir" "$prog" >/dev/null 2>&1
    t1=$(now_ms)
    noop_times="$noop_times$((t1 - t0))
"
  done
  noop_ms="$(printf '%s' "$noop_times" | median)"

  # ---- runtime and peak RSS ---------------------------------------------
  exe="$(python3 - "$work/$name.stats.json" <<'PY'
import json,sys
try:
    print(json.load(open(sys.argv[1]))["executable"]["path"])
except Exception:
    print("")
PY
)"
  run_ms="null"; peak_kb="null"
  if [ -n "$exe" ] && [ -x "$exe" ]; then
    run_times=""
    for _ in $(seq 1 "$RUNS"); do
      t0=$(now_ms)
      "$exe" >/dev/null 2>&1 || true
      t1=$(now_ms)
      run_times="$run_times$((t1 - t0))
"
    done
    run_ms="$(printf '%s' "$run_times" | median)"
    # peak RSS: GNU time reports it in kilobytes. `time` is a shell keyword, so
    # look for the binary explicitly; skip silently if there is no GNU time.
    gnutime="$(type -P gtime || type -P time || echo /usr/bin/time)"
    if [ -x "$gnutime" ]; then
      peak_kb="$("$gnutime" -f '%M' "$exe" 2>&1 >/dev/null | tail -1)"
      case "$peak_kb" in ''|*[!0-9]*) peak_kb="null" ;; esac
    fi
  fi

  stats="$(cat "$work/$name.stats.json" 2>/dev/null || echo '{}')"
  emit "$(python3 - "$name" "$prog" "$clean_ms" "$noop_ms" "$run_ms" "$peak_kb" "$stats" <<'PY'
import json,sys
name, prog, clean, noop, run, peak, stats = sys.argv[1:8]
def num(x):
    if x in ("null",""): return None
    try: return float(x) if "." in x else int(x)
    except ValueError: return None
try: st = json.loads(stats)
except Exception: st = {}
print(json.dumps({
  "program": name,
  "source": prog,
  "clean_build_ms": num(clean),
  "noop_rebuild_ms": num(noop),
  "runtime_ms": num(run),
  "peak_rss_kb": num(peak),
  "generated_c_bytes": st.get("generated_c", {}).get("bytes"),
  "executable_bytes": st.get("executable", {}).get("bytes"),
  "compiler_phases": {p["name"]: p["wall_ms"] for p in st.get("phases", [])},
}, sort_keys=True))
PY
)"
done
