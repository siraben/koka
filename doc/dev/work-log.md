# Work log

Newest first.  One entry per coherent piece of work: what was done, what was
discovered, and what was decided.

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
