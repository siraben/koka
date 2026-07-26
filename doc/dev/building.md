# Building this branch

This is the development branch of the Koka compiler used for the
Milestone-4 engineering program (an HTTP/JSON service on SQLite).  It differs
from upstream in two ways that matter for building:

* the language-server executable is behind a cabal flag (`langserver`, on by
  default) and is **not** built here;
* the tree carries a Nix flake so a clean machine can reproduce the build.

Primary supported environment: **Linux x86-64 with GCC or Clang**.  macOS ARM64
works through the same flake.  Windows is not supported by this program.

---

## 1. System dependencies

| what                     | why                                            |
| ------------------------ | ---------------------------------------------- |
| GHC 9.10.x               | the compiler is written in Haskell             |
| cabal-install 3.16+      | building the compiler                          |
| alex                     | generates `Syntax/Lexer.hs`                    |
| hpack                    | generates `koka.cabal` from `package.yaml`     |
| a C compiler (gcc/clang) | Koka compiles **to C**; needed at *runtime*    |
| cmake + make             | building `kklib` (the Koka C runtime)          |
| git                      | submodules, and git dependencies of projects   |
| pkg-config               | `[native]` dependencies of Koka projects       |
| sqlite3, libuv (dev)     | the Milestone 3/4 libraries bind against these |

Note the C compiler is not only a build dependency: the installed `koka` shells
out to a C compiler on every compilation.  The Nix build wraps the binary so it
always finds the same one it was built against.

### With Nix (recommended)

Everything above is provided by the flake:

```sh
nix develop            # compiler development shell (GHC, cabal, alex, hpack, cc, ...)
nix develop .#user     # shell that just has `koka` and the native libs on PATH
```

### Without Nix

Install GHC 9.10 and cabal (via ghcup), plus `alex`, `hpack`, `cmake`,
`pkg-config`, `libsqlite3-dev` and `libuv1-dev` from your distribution, then use
the cabal commands below.

---

## 2. Repository initialization

```sh
git clone <this repository> koka
cd koka
git submodule update --init --recursive   # kklib/mimalloc
```

The `mimalloc` submodule is required by `kklib`.  The Nix build does **not**
rely on the submodule being checked out — it pins the same commit explicitly in
`nix/koka.nix` — but a cabal build does.

Remotes on this branch:

* `origin` — `siraben/koka`, the owner's fork, with `dev` as its default
  branch.  All work goes here.  It is **public** by the owner's explicit
  decision; the compiler is Apache-2.0 and this branch adds no secrets.
* `upstream` — the public `koka-lang/koka` repository, **read only**.  Its push
  URL is deliberately set to an invalid value so a stray `git push upstream`
  fails instead of reaching it.  Pull requests are never opened.

---

## 3. Building the compiler

### Reproducible build (Nix)

```sh
nix build .#koka
./result/bin/koka --version
```

This builds `kklib` (with the pinned mimalloc), then the compiler with
`-f-langserver`, installs `koka-plain` as `bin/koka`, copies `lib/` (the Koka
standard library sources) into `share/koka/v<version>/`, and wraps the binary so
`CC`, `cmake` and `make` resolve to the exact store paths it was built against.

### Incremental build (development loop)

A full Nix rebuild takes ~15 minutes, which is too slow to iterate on the
compiler.  Inside the dev shell every Haskell dependency is already in the GHC
package database, so cabal only has to build this package:

```sh
nix develop
hpack                                                    # regenerate koka.cabal
cabal build --project-file=cabal.project.plain exe:koka-plain
cabal run   --project-file=cabal.project.plain exe:koka-plain -- --version
```

`cabal.project.plain` exists because the default `cabal.project` pulls a forked
`lsp` from git; that fork needs the network and does not build against this
branch.  Always pass `--project-file=cabal.project.plain` for compiler work.

After changing `package.yaml` (including adding a new module under `src/`), run
`hpack` again — module lists are generated.

---

## 4. Test commands

### Compiler test suite

The upstream suite is hspec-based and lives in `test/`.  It compiles the
programs under `test/**` and diffs against recorded `.out` files:

```sh
nix develop
cabal test --project-file=cabal.project.plain
```

The suite shells out to the compiler, so it needs a working C toolchain.

### Smoke test (fast, covers the whole pipeline)

```sh
./util/dev/smoke.sh ./result/bin/koka
```

This compiles and runs a hello-world through Koka → C → cc → executable.  It is
the cheapest check that the *generated-C path* is intact, and is what CI runs on
every push.

### Project-tooling tests

```sh
./util/dev/project-tests.sh ./result/bin/koka
```

Covers `koka init/fetch/build/run/test/clean`, lockfile determinism, and build
cache invalidation.

---

## 5. The generated-C compilation path

Understanding this path is essential when debugging build failures, because two
different compilers are involved.

```
  foo.kk
    │  koka: parse → type/effect check → core → optimize
    ▼
  <builddir>/v<ver>-<tag>/<cc>-<variant>-<hash>/foo.c , foo.h
    │  koka invokes $CC to compile each module to an object file
    ▼
  foo.o  (+ libkklib.a, built from share/koka/v<ver>/kklib via cmake)
    │  koka invokes $CC to link
    ▼
  foo__main   (native executable)
```

* the build directory defaults to `~/.koka/v<version>/...`, or `.koka/build/...`
  for a project build (see `doc/dev/architecture.md`);
* `--showc` prints the generated C; `-v2`/`-v3` show each C compiler invocation;
* `kklib` is compiled once per build variant and cached inside the build
  directory;
* `--stats=json` reports the size of the generated C and of the final
  executable, which is useful for spotting code-size regressions.

---

## 6. Common failures

**`Module 'Language.LSP.VFS' does not export 'VirtualFileEntry'`**
You built with the language server enabled against a newer `lsp`.  Use
`-f-langserver` (the flake and `cabal.project.plain` already do).

**`Cannot find source file: mimalloc/src/static.c`**
The `kklib/mimalloc` submodule is not checked out.  Run
`git submodule update --init --recursive`.  (Nix builds are immune: they fetch a
pinned mimalloc.)

**`cabal: ... /dist-newstyle/src/lsp-.../lsp: does not exist`**
You used the default `cabal.project`.  Pass
`--project-file=cabal.project.plain`.

**`koka: cannot find the C compiler`** (or link errors mentioning `cc`)
The compiler needs a C toolchain at *runtime*.  Use `nix develop .#user`, or
pass `--cc=<path>`.

**`pkg-config failed for [native] pkg-config = [...]`**
A project declared a native dependency that is not installed.  Install the
`-dev` package, or enter `nix develop .#user`, which provides sqlite and libuv.

**Stale results after changing the compiler**
Koka caches compiled modules per build variant.  A compiler change that alters
code generation without changing the version can be masked by the cache; pass
`--rebuild`, or delete `~/.koka` / the project's `.koka/build`.

**hspec suite reports diffs in `.out` files**
Some expected outputs are platform-specific.  Run with `--target=c` on Linux
x86-64 first; a diff on another platform is not necessarily a regression.

---

## 7. Sanitizers

```sh
koka --fasan -e program.kk
```

`--fasan` compiles with AddressSanitizer, UndefinedBehaviorSanitizer and leak
checking, and implies `--fstdalloc` (mimalloc hides leaks from the sanitizers).
The scheduled CI job runs the integration tests under this flag; see
`.github/workflows/sanitize.yml`.
