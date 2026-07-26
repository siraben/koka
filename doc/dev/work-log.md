# Work log

Newest first.  One entry per coherent piece of work: what was done, what was
discovered, and what was decided.

---

## Milestone 4 (part) — event loop, tasks, TCP, channels, JSON

**Concurrency architecture.**  Koka's C backend has no async support, so the
question was how to get one.  The decision, taken after a throwaway prototype
rather than on paper:

* **libuv behind a completion queue.**  A libuv callback would otherwise have
  to call into Koka, which means holding Koka closures in C and resuming
  continuations from arbitrary stack depths.  Instead every callback appends a
  record to a queue and Koka drains it.  All scheduling state lives in Koka; C
  holds handles and a queue.  Nothing else in the design was possible to reason
  about.
* **Tasks are an effect handler that captures continuations.**  `await-requests`
  files `resume` under one or more request ids; the run loop drives libuv and
  resumes the matching continuations.  The prototype that settled this is four
  dozen lines and was worth writing before committing to the approach.
* **A timeout is a race, not a poll.**  A task parks on *both* the operation's
  request id and a timer's, and whichever completes first wins.  `unpark`
  removes the whole entry so the loser cannot wake it twice.

Discovered:

* **`finally` cannot span a suspension point.**  This cost the most time and is
  the most important thing in this file.  When the scheduler's `ctl` handler
  captures a continuation and returns without resuming, Koka treats the
  computation as abandoned and runs `finally` handlers *immediately* -- so
  `with-socket(s) { read(s) }` closed the socket at the first read and the peer
  saw `ECANCELED`.  A minimal probe reproduced it in eight lines after the test
  suite pointed at it.

  The fix is not to patch `finally` but to release at a point that means
  something in this runtime: `runtime/task`'s `defer` registers a cleanup with
  the *task*, and the task runner runs it after the body has really ended --
  normally, by exception, or by unwinding from cancellation.  `finally` remains
  correct inside a task for regions that do not suspend, and outside tasks
  entirely.  Documented at `with-async-resource`, in the package README, and in
  ROADMAP known limitations.

* **A koka 3.2.7 inference bug.**  Dereferencing a `ref` inline inside a
  function that carries a user-defined effect makes the checker fail with
  `internal error: no empty iconstraints` and a dump of unresolved
  `hdiv<global,...>` constraints.  Wrapping each dereference in a monomorphic
  `io` helper discharges them.  The runtime package does this throughout and
  says why at each site.

* **Transitive path dependencies were resolved against the wrong directory.**
  `koka fetch` resolved a dependency's own path dependencies relative to the
  *root* project, so any graph deeper than one level broke unless every package
  happened to sit beside the root.  Found by moving a scratch project outside
  `koka-packages/`.  Fixed by threading the resolving base through the walk.

* **A cancelled group cancels its root task too**, so the root's next
  suspension point raises.  That is the correct reading of "a child task must
  not outlive its scope" -- the root is a task in the scope -- but it made two
  tests wrong rather than the runtime.  Recorded here because it is the kind of
  thing that looks like a bug the second time you meet it.

**JSON.**  Written against `:bytes` rather than `:string`, because that is what
arrives from a socket and because invalid UTF-8 must be a rejected request, not
a crashed decoder.  Every limit is enforced *while* parsing, so a 10000-level
nested document is refused rather than overflowing the stack -- there is a test
for exactly that.  Numbers are integers only: a fractional literal is reported
with its position rather than rounded, on the grounds that a service which
silently truncates a value is worse than one that refuses it.

---

## Milestone 3 — foundational libraries

Six packages, 149 tests, clean under ASan/UBSan/LSan.

Decisions:

* **`bytes` is built on the runtime's own `kk_bytes_t`**, so a byte sequence is
  an ordinary reference-counted Koka value and sharing is free.  The append
  builder is a malloc'd buffer wrapped in a raw C pointer box *with a free
  function*, so the runtime reclaims it even when `finish` is never called.
* **The hash map is a weight-balanced tree keyed on the hash**, not a HAMT.
  Koka's `:int` is arbitrary precision and has no bitwise operations, so a trie
  would have needed a detour through `int64`; an ordered tree needs only
  comparison.  Collisions live in a per-node bucket.  The balance invariant is
  asserted by the tests after every operation, and every property is checked
  against an association-list reference rather than against itself.
* **`resource/scope` is effect polymorphic and never uses `try`.**  Koka only
  subsumes *closed* effect rows, so a version written with `try` would work at
  one fixed effect and could not sit under a cancellation handler.  This
  constraint shaped several APIs and is written up in the package README.
* **`kktest` exits through `exit(3)`, not `_exit(2)`**, so LeakSanitizer's
  atexit check actually runs.  The suite reported "no leaks" for a while
  without ever having looked.

Discovered:

* Koka reserves `prefix`, `raw`, `handle` and `use` as keywords, and generates
  `is-<Constructor>` predicates that collide with hand-written names.  Both bite
  when translating C-shaped APIs.
* A multi-statement `fn` nested inside a call argument does not lay out
  cleanly; naming the body is the fix.

---

## Milestone 2 — project and dependency tooling

**Manifest, lockfile, commands, cache.**  Added `src/Compile/Project/`
(`Toml`, `Manifest`, `Hash`, `Lock`, `Fetch`, `Cache`, `Command`) and a
`ModeProject` in the option parser.

Decisions:

* **Build the tooling into the compiler**, not a separate driver.  A single
  `koka` binary is what the completion target asks for, and the project layer
  can reuse `compileAll` through a callback rather than reimplementing the
  build.
* **No version solving.**  A dependency is a path or a git repository pinned to
  a full 40-character commit.  A branch or tag is rejected outright, with a
  message saying so.  This is what makes `--locked` meaningful.
* **The cache key names the build directory.**  Koka already does per-module
  incremental compilation; what the project layer adds is choosing *which*
  build tree to use, keyed on everything that would invalidate all of it.  A
  no-op rebuild is then just Koka's own up-to-date check, and a stale artifact
  from a different compiler or profile is unreachable rather than merely
  unused.
* **The stamp file is written only on success**, so an interrupted build leaves
  a directory that fails validation and is discarded next time.

Discovered while testing:

* **A Koka program exits 0 after an uncaught exception.**  `std/core`'s
  `@default-exn` prints `uncaught exception: ...` and returns normally.  A test
  runner that trusted the exit status would report a crashed test as passing.
  `koka test` therefore runs each test binary itself and fails on either a
  non-zero exit status or that marker in the output.  Changing `@default-exn`
  to exit non-zero was considered and rejected: it changes the behaviour of
  every Koka program and would need matching runtime work, which is outside
  this program's scope.  Recorded in ROADMAP known limitations.
* **A parsec `sepEndBy` separator must be wrapped in `try`.**  Whitespace before
  a closing `}` was consumed while looking for a comma, so
  `{ path = "../greet" }` failed to parse.  Fixed in `Toml.pComma`.
* **A changed git pin must not be checksum-verified against the old entry.**
  The lockfile's checksum belongs to the commit it recorded; when the manifest
  moves the pin, that checksum is superseded, not violated.  Fixed in
  `Fetch.verify` by requiring the lock entry's source to match.
* **`koka build` only checks the import closure of the executable target.**  A
  project module nothing imports is never type checked.  Left as-is and
  recorded as a limitation; the reference service imports everything it ships.

## Milestone 1 — engineering baseline

**Reproducing the build.**  The environment had no C compiler, no GHC and no
Koka, but did have Nix.  Rather than fight `stack` (which wants to download a
GHC that will not run on NixOS), the build is a flake modelled on the nixpkgs
`koka` derivation with the source taken from the working tree.

Discovered:

* **Flakes do not copy submodule contents.**  `kklib/mimalloc` was missing and
  CMake failed on `mimalloc/src/static.c`.  Fixed by pinning mimalloc
  explicitly in `nix/koka.nix` with `fetchFromGitHub`, which is more
  reproducible than relying on submodule state anyway.
* **The language-server executable does not build against nixpkgs' `lsp`.**
  `Language.LSP.VFS` no longer exports `VirtualFileEntry`.  LSP work is out of
  scope, so `langserver` became a cabal flag (default on, so upstream behaviour
  is unchanged) and the flake builds with `-f-langserver`, installing
  `koka-plain` as `koka`.
* **The default `cabal.project` pulls a forked `lsp` from git**, which needs the
  network and does not build here.  Compiler work uses
  `cabal.project.plain`.
* A full nix rebuild is ~15 minutes; `nix develop` + cabal is ~30 seconds for a
  single-module change.  `util/dev/koka-dev.sh` runs the cabal-built compiler
  against the source tree as its share directory.

**Statistics.**  `Compile.Stats` collects into a process-global `IORef`.  A
handle threaded through the `Build` monad was considered; it buys nothing,
because there is exactly one compilation per invocation and the phase functions
are deep inside a concurrent build.  All updates go through
`atomicModifyIORef'`.

Phase timings are per-module sums and can exceed the total elapsed time, since
modules compile concurrently.  This is documented in the module header rather
than papered over.

Baseline on this machine (Linux x86-64, gcc 15.3, debug profile), from
`util/dev/bench.sh`:

| program                    | clean build | no-op rebuild | generated C | executable |
| -------------------------- | ----------- | ------------- | ----------- | ---------- |
| `samples/basic/fibonacci`  | 6.7 s       | 0.94 s        | 1.57 MB     | 4.74 MB    |
| `samples/handlers/basic`   | 8.9 s       | 2.11 s        | 2.45 MB     | 6.58 MB    |

Link dominates: ~15 s of per-module C compilation across 26 modules, wall
clock ~6.7 s at 16-way concurrency.  Recorded as a baseline only; no compiler
optimization work is in scope before Milestone 4 passes.
