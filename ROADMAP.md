# Roadmap

Target: **a Koka HTTP/JSON service backed by SQLite**, with concurrent request
handling, cancellation, reliable resource cleanup, testing, and reproducible
dependencies.

Scope is deliberately narrow.  Anything not needed by that service is out.

| milestone | status |
| --------- | ------ |
| 1. Engineering baseline      | done |
| 2. Project and package tooling | done |
| 3. Foundational libraries    | done |
| 4. HTTP/JSON/SQLite service  | built, one blocking defect |

---

## Milestone 1 — engineering baseline

- [x] reproducible build of this branch (`nix build .#koka`) on Linux x86-64
- [x] incremental development loop (`nix develop` + `cabal.project.plain`)
- [x] `doc/dev/building.md` — system deps, build, test, common failures,
      generated-C path
- [x] `doc/dev/architecture.md` — entry points, module resolution, inference,
      stdlib layout, generated C, runtime, FFI, tests, CLI, current
      file/socket/async support
- [x] CI: compiler build, generated-C smoke test, example compilation, project
      tooling tests, upstream test suite
- [x] scheduled sanitizer job: ASan + UBSan + leak checking, and a valgrind
      leak check
- [x] `--stats=json|text`: total wall clock, per-phase timings, generated C
      size, executable size
- [x] `util/dev/bench.sh`: clean build, no-op rebuild, runtime, peak RSS

Known deviations from upstream:

* the language-server executable is behind a cabal flag and off here (out of
  scope; does not build against the `lsp` in nixpkgs).

## Milestone 2 — project and dependency tooling

- [x] `koka.toml` manifest: package metadata, compiler constraint, source
      directories, path and exactly-pinned git dependencies, `[native]`
      pkg-config declarations, app and test targets
- [x] `koka.lock`: deterministic, sorted, no timestamps, content checksums,
      dependency graph, format version, corruption errors
- [x] `--locked` refuses to update the lockfile
- [x] `koka init | fetch | build | run | test | clean`
- [x] content-hash build cache keyed on compiler version, target, profile,
      flags, lockfile, sources, and native settings
- [x] 39 project tooling tests (`util/dev/project-tests.sh`)

Not implemented, by design: registry, publishing, semver solving, feature
flags, optional dependencies, aliases, workspaces, binary caches.

## Milestone 3 — foundational libraries

Packages under `koka-packages/`, 149 tests, clean under ASan/UBSan/LSan:

- [x] `kktest` — assertions, nested groups, expected failures, alarm-based
      watchdog timeouts, temporary directories, property testing with shrinking
- [x] `bytes` — immutable bytes over `kk_bytes_t`, slices, an amortized O(1)
      builder, strict UTF-8 validation, integer encoding, FNV-1a hashing
- [x] `strbuilder` — non-quadratic string building with RFC 8259 escaping
- [x] `hashmap` — persistent hash map and hash set, weight-balanced, checked
      against an association-list reference
- [x] `resource` — scoped acquire/use/release, effect polymorphic so it works
      under a cancellation handler

## Milestone 4 — HTTP/JSON/SQLite service

Done (59 tests, clean under ASan/UBSan/LSan):

- [x] event loop and timers (libuv), native handles kept internal behind a
      completion queue
- [x] structured tasks: scoped groups, spawn, failure propagation that cancels
      siblings, cooperative cancellation that unwinds through cleanup, timers,
      deadlines as a real two-request race
- [x] TCP and DNS, cancellable, with task-scoped socket release
- [x] bounded channels with producer backpressure and no silent loss
- [x] JSON: value type, parser with limits and source positions, generator

- [x] HTTP/1.1 server subset with conservative limits and a minimal router
- [x] SQLite bindings: prepared statements, transactions, migrations
- [x] structured logging as an effect
- [x] the reference service, its unit tests, and its integration/stress suite
- [x] `koka-examples` repository and its documentation

**Not yet passing:** the reference service serves every request correctly and
33 of its integration assertions pass, but a burst of concurrent connections
makes the server shut itself down. See the service README for exactly what has
been ruled out. Milestone 4's acceptance criteria are therefore not met.

---

## Known limitations

* Linux x86-64 is the only environment exercised in CI.  macOS ARM64 should
  work through the same flake but is untested here.
* `koka build` compiles the executable target and its import closure.  Project
  modules that nothing imports are not type checked.
* A Koka program exits 0 even on an uncaught exception, so `koka test` treats
  the runtime's `uncaught exception:` marker as a failure in addition to the
  exit status.
* Path dependencies are hashed on every command; for very large trees that
  cost is linear in the source size.
* **`finally` cannot span a suspension point inside a task.**  When the
  scheduler's handler captures a continuation and returns without resuming,
  Koka treats the computation as abandoned and runs `finally` handlers
  immediately.  Inside a task use `runtime/task`'s `defer` /
  `with-async-resource`, which release when the task really ends.  This is a
  property of the runtime design, not a bug that can be patched away, and it is
  documented at every affected API.
* koka 3.2.7's type inference fails with an internal error ("no empty
  iconstraints") when a `ref` is dereferenced inline inside a function carrying
  a user-defined effect.  Wrapping each dereference in a monomorphic `io`
  helper avoids it; the runtime package does this throughout.
* The task scheduler is single threaded and cooperative.  A task that never
  suspends is never interrupted, so a long computation must check
  `cancellation-requested` itself.
* Only IPv4 is supported by the TCP and DNS bindings.
