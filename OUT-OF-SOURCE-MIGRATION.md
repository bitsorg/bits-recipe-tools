<!--
SPDX-FileCopyrightText: 2026 CERN
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Out-of-source build migration — staged plan

## Goal

Make **every** CMake recipe build out-of-source from its private, per-build
rsync'd copy of the source — never from the shared, reused `SOURCES` tree — so
that any recipe which mutates its source in place (in-tree patching, code
generation, in-tree downloads; e.g. Davix's bundled-curl `git apply`) can no
longer poison `SOURCES` for the next build/arch. Then make that invariant
**enforced** by mounting `SOURCES` read-only in the build container.

Do this **without a flag-day**: separate the bulk mechanical recipe edits
(behavior-preserving) from the single behavior change (the flip), which is then
isolated, tested, and revertible on its own.

## Implementation status — COMPLETE

All stages are implemented and committed (build dir standardised on `build/`;
`common.bits`/`alice.bits` out of scope — obsolete/empty, and ALICE uses
alidist, which does not use bits-recipe-tools).

| Stage | What | Where |
|-------|------|-------|
| 1 | `CMakeRecipe` routes `Configure`/`Make`/`MakeInstall` through `BITS_CMAKE_SRC`/`BITS_CMAKE_BUILD` (no-op: `$SOURCEDIR` / `.`) | `bits-recipe-tools/CMakeRecipe` |
| 2 | 181 lcg recipes: `cmake "$SOURCEDIR"[/sub]` → `-S "$BITS_CMAKE_SRC"[/sub] -B "$BITS_CMAKE_BUILD"`; `--build .`/`--install .` → `"$BITS_CMAKE_BUILD"` (no-op) | `lcg.bits/*.sh` |
| 3 | The flip: drop `pushd build`, set `SRC="."`/`BUILD="build"`, `Prepare` excludes `/build/`; align Davix/xrootd | `CMakeRecipe`, `lcg.bits/{davix,xrootd}.sh` |
| 4 | Fix the 5 recipes that mutated SOURCES in place → write the copy | `lcg.bits/{root,gmp,k4geo,nlox,compilebox}.sh` |
| 5 | Read-only SOURCES tripwire **on by default** in docker (escape hatch `BITS_READONLY_SOURCES=0`; bind-mount overlay, no chmod) | `bits/bits_helpers/build.py` |
| 6 | CI lint guarding the invariant + this doc | `bits-recipe-tools/lint-out-of-source.sh` |

**Validation done statically**: 1098 lcg recipe bodies syntax-checked (0 new
failures); audited every `$SOURCEDIR` use — all remaining are reads (`cp` FROM
SOURCES into INSTALLROOT, `rsync` FROM SOURCES); no recipe `cd`/`pushd`es into
SOURCES; AutoTools/Make/Meson/Python/Pip recipe-tools already build from the
copy. **Still needs a runner build** of ROOT + a representative set (a plain
CMake pkg, xrootd, Boost, syscalc, CMake, Davix) to confirm the flip end-to-end
before relying on it; Stages 1–2 are no-ops and can be validated as a regression.

Run the lint from CI: `bits-recipe-tools/lint-out-of-source.sh lcg.bits`.

## Current state (facts)

- `CMakeRecipe.Run`: `mkdir build; pushd build` → `Prepare` (rsync
  `$SOURCEDIR/ → ./`) → `Configure` (`cmake "$SOURCEDIR"`) → `Make`
  (`cmake --build .`) → `MakeInstall` (`cmake --install .`) → `popd`. So cwd is
  `build/`, the copy is rsync'd into `build/` (coexisting with the binary), and
  the build is **out-of-source from the shared `$SOURCEDIR`**.
- `AutoToolsRecipe`: builds **in-source in the rsync'd copy** (no `pushd build`);
  `./configure`/`make`/`autoreconf` run on the copy. **Already safe** — no change.
- ~40 CMake recipes **override `Configure`** with their own `cmake "$SOURCEDIR"`
  (to add `-D` flags) and use the default `Make`. They build out-of-source from
  the shared tree.
- In-source-tool recipes (`syscalc`, Boost, apfel, geneva, …) override
  `Prepare`/`Make` to run `./b2`, `make -C src`, `sed`, etc. on the copy at cwd.
  They already operate on the copy (safe), but assume cwd is `build/`.
- `Davix`: already converted to build-from-copy (`cmake -S . -B obj`).
- Tripwire: opt-in `BITS_READONLY_SOURCES` (overlay `:ro` mount on `SOURCES` in
  the container) — committed, **off by default**.

## Target end state

- `CMakeRecipe` is cwd-invariant: copy at cwd, out-of-source build in a `build/`
  subdir; `Configure` = `cmake -S . -B build`, `Make` = `cmake --build build`,
  `MakeInstall` = `cmake --install build`; **no `pushd`/`cd` that leaks** into
  later stages.
- All overriding recipes go through the same source/build indirection.
- In-source-tool recipes operate on cwd = the copy.
- `BITS_READONLY_SOURCES` enabled by default (invariant enforced).

## Mechanism: source/build indirection (this is what enables safe staging)

Add two variables to `CMakeRecipe`:

- `BITS_CMAKE_SRC`   — directory cmake uses as the source.
- `BITS_CMAKE_BUILD` — the binary directory.

The default `Configure`/`Make`/`MakeInstall` use them. Recipes that override
`Configure` use `cmake -S "$BITS_CMAKE_SRC" -B "$BITS_CMAKE_BUILD" <flags>`
instead of `cmake "$SOURCEDIR"`. **Flipping the two variables' values flips every
recipe at once** — so the mechanical edits (Stages 1–2) change nothing, and the
behavior change (Stage 3) is two assignments + the `Run` restructure.

## Stages

### Stage 0 — Inventory & test harness (no code change)
- Categorize every `CMakeRecipe` user:
  - (a) default `Configure` — auto-fixed by the framework;
  - (b) override `Configure` with `cmake "$SOURCEDIR"` — the ~40 to convert;
  - (c) override `Prepare`/`Make` for in-source tools — to audit;
  - (d) other (bootstrap, e.g. `cmake.sh`; `Configure(){ :; }`, e.g. `syscalc`).
- Pick a representative test set: a plain default-`Configure` package
  (`spdlog`/`yamlcpp`), `xrootd` (override `Configure`), Boost (in-source `./b2`),
  `syscalc` (in-source autotools-in-cmake), `CMake` (bootstrap), `Davix`
  (already converted), plus **ROOT end-to-end**.
- Record current package hashes for regression comparison.

### Stage 1 — Introduce the indirection, **no behavior change**
- `CMakeRecipe`: set `BITS_CMAKE_SRC="$SOURCEDIR"` and `BITS_CMAKE_BUILD="."`
  (the *old* values) and rewrite the default `Configure`/`Make`/`MakeInstall` to
  use them (`cmake -S "$BITS_CMAKE_SRC" -B "$BITS_CMAKE_BUILD" …`,
  `cmake --build "$BITS_CMAKE_BUILD"`, `cmake --install "$BITS_CMAKE_BUILD"`).
- Result is byte-for-byte the current behavior (source `$SOURCEDIR`, binary cwd).
- **Test:** build the representative set; hashes identical to Stage 0.

### Stage 2 — Convert the overriders, **no behavior change**
- For each of the ~40 recipes overriding `Configure`:
  `cmake "$SOURCEDIR" …` → `cmake -S "$BITS_CMAKE_SRC" -B "$BITS_CMAKE_BUILD" …`.
  (Davix already uses `-S . -B obj`; align to `build` or leave.)
- Mechanical and scriptable, but review each (some pass extra positional args).
- **Test:** representative set still identical (variables still old).

### Stage 3 — Flip to build-from-copy (**the one behavior change**)
- `CMakeRecipe.Run`: drop `mkdir build; pushd build` / `popd`; run all stages in
  cwd (the working dir). `Prepare` rsyncs `$SOURCEDIR/ → ./` (copy at cwd) with
  `--exclude '/build/'` so the binary dir survives incremental rebuilds.
- Set `BITS_CMAKE_SRC="."` and `BITS_CMAKE_BUILD="build"`.
- Now every default + converted recipe builds out-of-source from the copy into
  `build/`; cwd is invariant; nothing writes back into `SOURCES`.
- **Test:** full ROOT build + the representative set on a real runner. This is
  the risky commit — one commit, revertible, gated on the test pipeline.

### Stage 4 — Fix in-source-tool recipes for the new cwd
- These override `Prepare`/`Make` and used to run with cwd = `build/`; now cwd is
  the working dir (the copy). Audit each for: hard references to `build/`,
  `cd`/`pushd`, or absolute-cwd assumptions. Relative-path recipes (`./`,
  `make -C src`) are unaffected.
- `syscalc` (rsync `→ ./`, `sed`, `make -C src`), Boost (`./bootstrap.sh`,
  `./b2`), apfel/geneva/…: verify and fix any that hardcode the old layout.
- **Test:** each in-source recipe individually.

### Stage 5 — Enforce read-only SOURCES
- Turn `BITS_READONLY_SOURCES` on (default, or set in CI/console).
- Build ROOT; any remaining in-place mutator now fails loudly with EROFS → fix
  it Davix-style (build out-of-source from the copy). Iterate until clean.

### Stage 6 — Finalize
- Document the invariant in `CMakeRecipe` and a contributor note: *recipes must
  build out-of-source from the copy; never write `$SOURCEDIR`*.
- Add a CI lint that greps recipes for `cmake "$SOURCEDIR"` (and in-tree writes)
  and fails — so the invariant can't silently regress.

## Risk & rollback
- Stages 1–2 are behavior-preserving → low risk, independently revertible.
- Stage 3 is the only risky change → isolated in one commit, validated by the
  test set before merge, revertible by itself (Stages 1–2 are harmless if 3 is
  reverted).
- Stages 4–5 are per-recipe and incremental.
- Each stage is its own commit set across `bits-recipe-tools` (framework),
  `lcg.bits`/`common.bits` (recipes), and `bits` (tripwire default).

## Open decisions
- Binary dir name: standardize on `build` (Davix currently uses `obj`).
- Do the `common.bits`/`alice.bits` CMake recipes use this `CMakeRecipe` or
  `alibuild-recipe-tools`? If the latter, they need the equivalent pass.
- Confirm the incremental `Build` target (which skips `Prepare`) behaves under
  the new layout (copy + `build/` both persist across invocations).
