# Architecture map

Only the parts this engineering program touches.  This is not a complete
description of the compiler.

```
  src/
    Main/            executables (plain / language server / playground)
    Compile/         the driver: options, module graph, build, codegen, project tooling
    Syntax/          lexer, layout, parser, concrete syntax
    Static/          binding groups, fixity resolution
    Kind/            kind inference, type/effect declarations
    Type/            type and effect inference, unification, pretty printing
    Core/            core IR and its passes (simplify, inline, monadic, ctail, ...)
    Backend/         C / JavaScript / C# code generation
    Platform/        OS abstraction (native under Platform/cpp)
    Lib/             pretty printer, printer, JSON reader, misc
  lib/               the Koka standard library, written in Koka
  kklib/             the C runtime (Perceus, boxing, effect handlers) + mimalloc
  test/              hspec-driven golden test suite
  util/dev/          scripts added by this program (smoke, project tests, bench)
```

---

## 1. Compiler entry points

| file                         | role                                              |
| ---------------------------- | ------------------------------------------------- |
| `src/Main/plain/Main.hs`     | `koka-plain`, installed as `koka` in this branch   |
| `src/Main/langserver/Main.hs`| LSP-enabled `koka` (disabled here, see building.md)|
| `src/Main/Run.hs`            | shared driver: parses options, dispatches on `Mode`|

`Main.Run.runWithLSArgs` calls `Compile.Options.getOptions` and then
`mainMode`, which switches on `Mode`:

* `ModeCompiler files` — compile (and optionally run) the given files
* `ModeInteractive`    — the REPL (`Interpreter.Interpret`)
* `ModeProject cmd`    — **added by this program**: `koka build/run/test/...`
* `ModeLanguageServer`, `ModeHelp`, `ModeVersion`

`compileAll` is the one function that turns a list of source paths into built
artifacts; project commands reuse it through a callback rather than
reimplementing the build.

## 2. Command-line interface

`src/Compile/Options.hs` holds:

* `data Flags` — one big record of every knob, with a `Hashable` instance over
  the *build-relevant* subset.  `flagsHash` from that instance is what names
  the build variant directory, and it is also folded into the project cache key.
* `optionsAll` — the option table (`option`/`flag`/`fflag`/`numOption` helpers).
* `parseOptions` — pure; produces `(Flags, Mode)`.
* `processInitialOptions` — the IO half: detects the C compiler, the target
  architecture, the install directories, and resolves the project-subcommand
  ambiguity (`koka build` vs a file called `build.kk`).
* `fullBuildDir` — `<buildDir>/v<version>-<buildtag>/<cc>-<variant>-<flagshash>`.
  Everything downstream derives paths from this, which is why redirecting
  `buildDir` is enough to give a project its own content-addressed build tree.

## 3. Module resolution

`src/Compile/Build.hs` (`modulesResolveDependencies`) walks imports to a
fixpoint.  A module is found by searching `includePath` for
`<name>.kk`; a compiled interface (`.kki`) in the build directory is used
instead when it is newer than the source and its own imports are unchanged.
`Compile.Module` holds the per-module record (`modPhase`, `modCore`,
`modIfaceTime`, ...).

Project builds simply prepend the project's and its dependencies' source
directories to `includePath`, so dependency resolution needs no special case in
the compiler.

Note `src/Compile/Package.hs` is legacy npm-style package discovery.  It is
unused by the project tooling and was left alone.

## 4. Type and effect inference

* `Kind/Infer.hs` — kind inference over declarations; produces the newtypes,
  synonyms and constructor tables.
* `Type/Infer.hs` — the main bidirectional inference pass, producing `Core`.
  Effects are rows; `Type/Unify.hs` does row unification.
* `Compile/TypeCheck.hs` — the thin wrapper the build calls per module.

Effect inference is the reason a change to an *exported effect* invalidates
dependents just like a type change does; the project test suite asserts this.

## 5. Core and optimization

`Compile/Optimize.hs` (`coreOptimize`) runs the pipeline that is **not**
optional: monadic translation for effectful code, `Core.FunLift`,
`Core.Simplify`, `Core.Inline`, `Core.Specialize`, `Core.CTail` (TRMC), and the
Perceus passes `Backend.C.Parc` / `ParcReuse` / `ParcReuseSpec` which insert
reference-count operations and in-place reuse.

Nothing in this program changes these passes; speculative compiler optimization
is out of scope.

## 6. Generated C and the runtime

`Backend/C/FromCore.hs` emits one `.c` and one `.h` per module into the build
directory.  `Compile/CodeGen.hs` then invokes the C compiler:

```
codeGen ─→ FromCore (emit .c/.h) ─→ cc -c  ─→ .o
                                 └→ cc     ─→ executable  (links libkklib.a)
```

`kklib/` is the runtime: reference counting (`kk_block_t`, drop/dup), boxing,
the effect-handler mechanism (`kklib/src/*.c`, `include/kklib/*.h`), and
mimalloc.  It is compiled once per build variant by CMake and cached inside the
build directory.

Useful switches: `--showc` (print generated C), `-v2`/`-v3` (show each C
compiler invocation), `--stats=json` (sizes and phase timings).

## 7. Native FFI

Koka calls C through `extern` declarations plus an inline C file:

```koka
extern import
  c file "file-inline.c"

extern read-byte(fd : int32) : int32
  c "kk_my_read_byte"
```

Conventions worth knowing before writing bindings (see `lib/std/os/*.kk` and
`lib/std/num/int64-inline.c` for worked examples):

* every `extern` C function takes an extra `kk_context_t* _ctx` argument;
* arguments arrive as `kk_box_t`/`kk_string_t`/`kk_integer_t`, and the callee
  **owns** them — it must `kk_..._drop` what it does not return;
* returning a value transfers ownership to the caller;
* a foreign resource that must be released is normally an `intptr_t` handle
  wrapped in a Koka value, with release driven from Koka (this is what the
  scoped-resource abstraction in Milestone 3 builds on).

The `[native]` section of `koka.toml` feeds `pkg-config` results into
`ccompIncludeDirs` / `ccompLinkSysLibs`, so a package can depend on `sqlite3`
or `libuv` without the user writing C flags.

## 8. Tests

* `test/Spec.hs` — hspec runner.  It walks `test/**`, compiles each `.kk` file
  with the compiler under test and diffs stdout against a recorded `.out`.
  Configuration lives in per-directory `config.json` files.
* `util/dev/smoke.sh` — end-to-end generated-C smoke test (CI, every push).
* `util/dev/project-tests.sh` — the project tooling: manifests, lockfile
  determinism, `--locked`, cache invalidation, git pins.
* `util/dev/bench.sh` — clean build / no-op rebuild / runtime / peak RSS.

## 9. Project tooling (added by this program)

```
  src/Compile/Project/
    Toml.hs      small TOML reader (the manifest subset only)
    Manifest.hs  koka.toml schema + compiler version constraints
    Lock.hs      koka.lock: deterministic read/write, corruption errors
    Hash.hs      SHA-256 content hashing (tree hashes, cache keys)
    Fetch.hs     dependency graph resolution, git checkouts of pinned commits
    Cache.hs     cache key -> build directory, stamp validation
    Command.hs   init / fetch / build / run / test / clean
  src/Compile/Stats.hs   machine readable phase timings and artifact sizes
```

On-disk layout of a project:

```
  koka.toml
  koka.lock
  .koka/
    deps/<name>-<short rev>/     git dependencies, immutable once fetched
    build/<cache key>/           one tree per (compiler, target, profile,
      cache-key.txt              flags, lockfile, sources, native settings)
      v<ver>-<tag>/<variant>/    ... and inside it, koka's own build tree
```

## 10. Current file, socket, and async support

State of the standard library as of this branch, which is what Milestones 3
and 4 build on:

| area        | what exists                                                                  |
| ----------- | ---------------------------------------------------------------------------- |
| files       | `lib/std/os/file.kk` — whole-file read/write only (`read-text-file`, `write-text-file`), backed by `file-inline.c`. No handles, no streaming, no scoped close. |
| directories | `lib/std/os/dir.kk` — listing and creation.                                  |
| paths       | `lib/std/os/path.kk`.                                                        |
| processes   | `lib/std/os/process.kk` — run a command.                                     |
| async       | `lib/std/async/*.kk` — only present for the **JavaScript** backend; there is no async story for the C backend. |
| tasks       | `lib/std/os/task.kk` — a thin wrapper over OS threads.                        |
| sockets     | none.                                                                        |
| timers      | none for the C backend.                                                       |
| hash maps   | `lib/std/data/dict.kk` (string keys only), plus persistent `map`/`set`/`imap`/`iset`. No general hash map. |
| bytes       | none — `string` and `vector<char>` only.                                      |

So Milestone 3 and 4 add, as packages rather than compiler changes: bytes and
builders, a general hash map, scoped resources, real file handles, and a libuv
backed event loop with timers, TCP, and structured tasks.
