# Roadmap

Target: **a Koka HTTP/JSON service backed by SQLite**, with concurrent request
handling, cancellation, reliable resource cleanup, testing, and reproducible
dependencies.

Scope is deliberately narrow.  Anything not needed by that service is out.

| milestone | status |
| --------- | ------ |
| 1. Engineering baseline      | done |
| 2. Project and package tooling | done |
| 3. Foundational libraries    | in progress |
| 4. HTTP/JSON/SQLite service  | not started |

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

Packages under `koka-packages/`:

- [ ] `test` — assertions, groups, discovery, expected failures, deterministic
      output, temp files, timeouts, property testing with shrinking
- [ ] `bytes` — immutable bytes, slices, builders, encoding helpers, hashing
- [ ] `strbuilder` — non-quadratic string building with escaping
- [ ] `hashmap` — hash map and hash set with documented iteration order
- [ ] `resource` — one scoped acquire/use/release abstraction
- [ ] `fileio` — handles, streaming reads, atomic replace, temp files, metadata

## Milestone 4 — HTTP/JSON/SQLite service

- [ ] structured tasks: scoped groups, spawn, await, failure propagation,
      cancellation, timeout, racing, shutdown
- [ ] event loop and timers (libuv), with native handles kept internal
- [ ] TCP and DNS, integrated with scoped resources
- [ ] bounded channels with producer backpressure
- [ ] JSON: value type, parser with limits and positions, generator
- [ ] HTTP/1.1 server subset with conservative limits and a minimal router
- [ ] SQLite bindings: prepared statements, transactions, migrations
- [ ] structured logging as an effect
- [ ] the reference service and its unit, integration, and stress tests

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
