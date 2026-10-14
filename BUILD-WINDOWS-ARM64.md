# Building GHC for Windows ARM64 (aarch64) with MSYS2

This guide builds a **native Windows ARM64 GHC** on a Windows ARM64 machine
(tested on a Snapdragon X / SC8380XP, Windows 11). No official Windows ARM64
GHC exists to bootstrap from, so the build goes through two stages:

1. The official **x86_64** Windows GHC (running under Windows' x64 emulation)
   builds a **cross-compiler**: x86_64 host, `aarch64-unknown-mingw32` target.
2. That cross-compiler builds the **native ARM64** `ghc.exe` and the other
   programs (Hadrian "stage3").
3. Optionally, that native ARM64 GHC bootstraps a second, fully native build
   with GHCi and Template Haskell (section 6).

Tested against GHC `10.1` (master at `f217fc315b`). Windows ARM64 support first
appeared in the 9.14 release line.

---

## 1. Prerequisites

### MSYS2 packages

Open the **MSYS2 CLANGARM64** shell and run:

```bash
pacman -Syu        # repeat until nothing is left to update
pacman -S --needed git tar unzip patch make autotools python \
  mingw-w64-clang-aarch64-toolchain mingw-w64-clang-aarch64-lld \
  mingw-w64-clang-aarch64-llvm
```

This provides the target toolchain in `C:\msys64\clangarm64\bin`: clang/lld/LLVM.
LLVM 20 or newer is required; the build was tested with 23.1.3.

### Bootstrap tools (x86_64)

| Tool | Version used | Location used in this guide |
|---|---|---|
| GHC (x86_64-unknown-mingw32 bindist) | 9.12.3 (≥ 9.10 required) | `/opt/ghc-9.12.3` |
| cabal-install (x86_64 Windows) | 3.14+ | `/opt/cabal` |
| alex / happy | 3.5.4.2 / 2.2 | `~/.local/bin` (via `cabal install alex happy`) |

### Source

```bash
git clone --recursive <your ghc repo> ~/Project/ghc
cd ~/Project/ghc
git submodule update --init --recursive
```

---

## 2. Source fixes required

Upstream only tests Windows ARM64 as a cross-compile **from Linux**. Building
on Windows hits the bugs below. The fixes are in this working tree:

| File | Problem | Fix |
|---|---|---|
| `configure.ac`, `m4/fp_cc_supports_target.m4`, `m4/fp_prog_cc_linker_target.m4` | The stage0 (host) C compiler was given `--target=aarch64-…` instead of the build platform's triple. A clang host compiler then can't find its own headers: `Error … no rule available: sys/types.h`. | Stage0 checks now use `$LlvmBuildTarget`, computed from `$build`. |
| `configure.ac`, `hadrian/cfg/system.config.host.in` | `use-lib-rt = YES` was hardcoded for the host, which fails on Windows: `Missing (or bad) C library: rt`. | New `@UseLibrtHost@`: `NO` on mingw32/darwin hosts. |
| `configure.ac`, `m4/prep_target_file.m4`, `hadrian/cfg/default.host.target.in` | The host target had no windres, so the stage1 compiler failed to link any executable: `builderMainLoop: invalid argument`. An empty merge-objects command became `"."`. | windres comes from the bootstrap GHC's `--info`. Merge-objects is `Nothing` when empty. |
| `utils/hsc2hs/src/ATTParser.hs` (submodule) | clang ≥ 21 emits CodeView `.debug$S` records on COFF, and hsc2hs `--via-asm` attached them to the last constant: `Cannot combine instructions: [Quad 8,Long 4,Long 241,…]`. No clang flag disables these records. | The parser drops `.debug*` sections. |
| `utils/ghc-pkg/Main.hs` | `ghc-pkg describe --expand-pkgroot` didn't expand `${pkgroot}` in `library-dirs-static`. Hadrian copies the bootstrap compiler's packages this way, so static links searched the wrong directory: `lld: error: unable to find library -lHSbase-…`. Only matters when bootstrapping (section 6). | `mungePackagePaths` now expands `libraryDirsStatic` too, like GHC's own `mungeUnitInfoPaths`. |
| `rts/linker/PEi386.c`, `rts/linker/PEi386Types.h` | GHCi's object loader had only placeholder ARM64 support, so `ghc -e`, `ghci` and Template Haskell failed with `PE/PE+ not supported on ARM64.` | Implements the ARM64 COFF relocations, jump islands for far targets (see `Note [ARM64 jump islands]`), `.pdata` registration and instruction-cache flushing. Also treats `IMAGE_SYM_CLASS_LABEL` symbols (LLVM's `$L.text_N`) as local, and handles the `SECREL*` relocations that `libc++abi` uses for thread-local variables. |
| `compiler/GHC/CmmToAsm/AArch64/Ppr.hs` | The ARM64 code generator printed a literal's `.p2align` *after* its label. For 16-byte SIMD constants that follow code in `.text`, the label could end up pointing at `nop` padding, so the low half of the vector was garbage (e.g. `-3097596797610942433` = two `nop`s). | Aligns the label for the most strictly aligned item it labels. |
| `linters/lint-codes/LintCodes/Coverage.hs` | The `codes` test failed with `C:\home\…\testsuite\tests: … does not exist`. MSYS git returns `/home/user/ghc` for a checkout inside the MSYS root, which Windows programs can't resolve. | Gets the tree root with `git rev-parse --show-cdup` (a relative path) instead. |
| Tests: `ghci/should_run/T25636f`, `ghc-heap/tests/create_tso.c`, `rts/T7289` | Two tests assumed tables-next-to-code, and `T7289` reads the x87 FPU control word. | Pass the right info-table layout; skip `T7289` on non-x86. |
| `hadrian/src/Settings/Builders/RunTest.hs` | `ifMinGhcVer` compared versions as strings, so with a 10.x bootstrap compiler (`"1001"` < `"801"`) the testsuite ran without `-fno-diagnostics-show-caret` and three other flags. About 3,400 tests failed with `stderr mismatch`. | Compares the versions as numbers. |
| `testsuite/tests/codeGen/should_run/all.T` | `CallConv`'s assembly only works with tables-next-to-code, which Windows ARM64 doesn't use. It crashed with *"Access violation … when executing data"*. | Skip the test without tables-next-to-code. |

> `utils/hsc2hs` is a submodule, so `git status` shows it as modified (`m`).
> Commit that change in the submodule if you want to keep it.

After changing `configure.ac` or anything in `m4/`, regenerate `configure` with
`python3 boot`.

---

## 3. Environment

Put the following in a file (e.g. `~/ghc-arm64-env.sh`) and `source` it in every
CLANGARM64 shell you build from:

```bash
# GHC-built tools (hsc2hs) read/write files using the console code page.
# Sources contain UTF-8 (e.g. "μs"), so the default code page 437 breaks the build.
chcp.com 65001 > /dev/null

export PATH=/opt/ghc-9.12.3/bin:/opt/cabal:$HOME/.local/bin:$PATH

# Target (aarch64) toolchain. Use C:/ paths, NOT /c/ or /clangarm64/ paths:
# GHC and Hadrian are native Windows programs and cannot resolve MSYS paths.
T=C:/msys64/clangarm64/bin
export CC=$T/clang.exe CXX=$T/clang++.exe LD=$T/ld.lld.exe \
       AR=$T/llvm-ar.exe NM=$T/llvm-nm.exe RANLIB=$T/llvm-ranlib.exe \
       OBJDUMP=$T/llvm-objdump.exe STRIP=$T/llvm-strip.exe \
       WindresCmd=$T/llvm-windres.exe DlltoolCmd=$T/llvm-dlltool.exe \
       LLC=$T/llc.exe OPT=$T/opt.exe LLVMAS=$T/clang.exe MergeObjsCmd=""

F="--rtlib=compiler-rt -D_UCRT"
export CFLAGS="$F" CONF_CC_OPTS_STAGE1="$F" CONF_CC_OPTS_STAGE2="$F"
export CONF_GCC_LINKER_OPTS_STAGE1="-fuse-ld=lld $F" CONF_GCC_LINKER_OPTS_STAGE2="-fuse-ld=lld $F"
```

---

## 4. Build

All commands run from `~/Project/ghc` in the CLANGARM64 shell, with the
environment from step 3 sourced.

### 4.1 Fetch the x86_64 host MinGW toolchain (one time)

The intermediate stage1 compiler runs on the x86_64 side and needs GHC's
bundled x86_64 MinGW in `inplace/mingw`. With `--enable-distro-toolchain`
(step 4.2), configure does not download it, so fetch it first with a plain
native x86_64 configure:

```bash
python3 boot
./configure --build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32 \
  --enable-tarballs-autodownload GHC=$(which ghc)
ls inplace/mingw/bin/clang.exe     # must exist
```

### 4.2 Configure the cross build

```bash
./configure --build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32 \
  --target=aarch64-unknown-mingw32 --enable-distro-toolchain --disable-numa \
  GHC=$(which ghc) ALEX=$(which alex) HAPPY=$(which happy)
```

All of the following must hold:
- `--build` and `--host` are **x86_64**. If `--build` is left out, the
  CLANGARM64 shell makes autoconf guess `aarch64` and configure stops with
  *"This GHC … does not generate code for the build platform"*.
- `--enable-distro-toolchain` is passed. Without it, configure replaces the
  target toolchain with the bundled x86_64 MinGW, and linking fails with
  *"machine type x64 conflicts with arm64"*.
- The summary shows `Target platform : aarch64-unknown-mingw32`.
- This command prints **nothing**. Any output means an MSYS path got in:

  ```bash
  grep -n '"/c/\|= /c/' hadrian/cfg/system.config hadrian/cfg/default*.target
  ```

### 4.3 Build the cross-compiler and ARM64 libraries (~1h15m)

```bash
hadrian/build -j --flavour=default+native_bignum --docs=none binary-dist-dir 2>&1 | tee build-cross.log
```

`native_bignum` avoids needing GMP for ARM64. The result is
`_build/stage1/bin/aarch64-unknown-mingw32-ghc.exe`, an x86_64 program that
produces ARM64 executables. Quick check:

```bash
echo 'main = putStrLn "hello"' > hello.hs
_build/stage1/bin/aarch64-unknown-mingw32-ghc.exe hello.hs -o hello.exe
file hello.exe     # PE32+ … ARM64
./hello.exe
```

### 4.4 Build the native ARM64 GHC (stage3)

```bash
hadrian/build -j --flavour=default+native_bignum --docs=none \
  stage3:exe:ghc-bin stage3:exe:ghc-pkg stage3:exe:unlit stage3:exe:hsc2hs
file _build/stage2/bin/*.exe          # all ARM64
```

(`binary-dist-stage3` can't be used: its rule is disabled in
`hadrian/src/Rules/BinaryDist.hs` as "Not working yet".)

---

## 5. Install the native ARM64 GHC

Copy the stage2 output to its own folder and apply two small workarounds:

```bash
D=/c/ghc-arm64                         # any location
mkdir -p $D
cp -r _build/stage2/bin _build/stage2/lib $D/

# GHC on Windows refuses to start unless a "mingw" directory exists next to it,
# even when the distro (clangarm64) toolchain is used. An empty one is enough.
mkdir -p $D/mingw

# The settings file names unlit with the cross prefix.
cp $D/bin/unlit.exe $D/bin/aarch64-unknown-mingw32-unlit.exe
```

Check:

```bash
$D/bin/ghc.exe --info | grep -E 'Host platform|Target platform'
#  ,("Host platform","aarch64-unknown-mingw32")
#  ,("Target platform","aarch64-unknown-mingw32")
$D/bin/ghc.exe -O hello.hs -o hello.exe && ./hello.exe
```

The installed compiler calls the MSYS2 clangarm64 tools by absolute path
(`C:/msys64/clangarm64/bin`), so MSYS2 must stay installed at that location.

---

## 6. Rebuild natively

The compiler from section 5 has no interpreter (see section 7). This section
builds GHC again **natively**, using `C:\ghc-arm64` as the bootstrap compiler.
The result includes GHCi and Template Haskell. These need the RTS linker fix
from section 2.

> **Status:** the native build completes and GHCi and Template Haskell work.
> A full testsuite run gave 11,865 expected passes and 26 unexpected
> failures. After the fixes in section 2, those 26 come down to `T9329`
> (section 7) and 10 profiling tests that need the `late_ccs` flavour
> (see 6.4). The full testsuite hasn't been rerun since then.

The bootstrap compiler is a development snapshot (`10.1.x`), not a release.
Hackage packages and Hadrian don't fully support it yet, which is why
sections 6.2–6.4 need workarounds. If you have a **released** ARM64 Windows
GHC, use it as the bootstrap instead. Then skip 6.1–6.2 and drop
`--enable-bootstrap-with-devel-snapshot`.

Use the CLANGARM64 shell with the environment from step 3, but put the
ARM64 GHC first on `PATH`:

```bash
source ~/ghc-arm64-env.sh
export PATH=/c/ghc-arm64/bin:$PATH
which ghc            # /c/ghc-arm64/bin/ghc
```

### 6.1 Fix the bootstrap package database (one time)

The `ghc-pkg` in `C:\ghc-arm64` was built before the `ghc-pkg` fix in
section 2. It leaves `${pkgroot}` unexpanded in `library-dirs-static` when
Hadrian copies packages, which makes every link fail with
`lld: error: unable to find library -lHS…-inplace`. Work around it by writing
that field as an absolute path in the bootstrap's own package files:

```bash
D=/c/ghc-arm64
W=$(cygpath -m $D/lib)                                  # C:/ghc-arm64/lib
cp -r $D/lib/package.conf.d $D/lib/package.conf.d.bak   # backup
sed -i "/^library-dirs-static:/{n;s|[\$]{pkgroot}|$W|}" $D/lib/package.conf.d/*.conf
$D/bin/ghc-pkg.exe recache
$D/bin/ghc-pkg.exe field base library-dirs-static       # must show C:/ghc-arm64/lib\…
```

This changes only the `library-dirs-static` lines, one per package. The
install now depends on staying at `C:\ghc-arm64`. To undo, copy the backup
back and run `ghc-pkg recache`. A bootstrap GHC built from this tree *after*
the `ghc-pkg` fix doesn't need this step.

### 6.2 Let Hadrian's dependencies build with the snapshot's `base`

Hadrian is built by cabal from Hackage packages. They fail with the
snapshot's `base-4.23` in two ways:

- Every `hashable` release requires `base < 4.23`:
  `Could not resolve dependencies … hashable => base>=4.18.0.0 && <4.23`.
- `base-4.23` no longer exposes `GHC.Num.{BigNat,Integer,Natural}`
  (CLC proposal #359, see `libraries/base/changelog.md`), and hashable
  imports them: `Could not load module 'GHC.Num.BigNat' … hidden package 'ghc-bignum'`.

Create `hadrian/cabal.project.local`. cabal reads it automatically next to
`hadrian/cabal.project`, and it isn't committed:

```cabal
-- Local workaround for bootstrapping with a GHC devel snapshot (base-4.23).
allow-newer: all

-- base-4.23 no longer exposes GHC.Num.{BigNat,Integer,Natural} (CLC #359).
package hashable
  ghc-options: -package ghc-bignum
```

Delete this file when you bootstrap with a released GHC.

### 6.3 Configure

```bash
./configure --enable-distro-toolchain --enable-bootstrap-with-devel-snapshot \
  GHC=/c/ghc-arm64/bin/ghc.exe
```

`--enable-bootstrap-with-devel-snapshot` is required. Without it, configure
stops with *"… is a development snapshot of GHC … Bootstrapping using this
version of GHC is not supported"*. The summary must show `aarch64-unknown-mingw32`
for the build, host and target platforms. Run the MSYS path check from
step 4.2 again.

### 6.4 Build in a separate build root

`_build` still contains the cross build from section 4. Its stage0 package
database registers the x86_64 bootstrap compiler's `rts`, whose headers are
x86_64. Hadrian doesn't notice that the bootstrap compiler changed, so reusing
`_build` makes the ARM64 GHC fail with
`panic! (the 'impossible' happened) … Invalid platform constants`. Build into a
fresh directory instead, which also keeps the cross build intact:

```bash
mkdir -p _build-native/mingw
hadrian/build -j --build-root=_build-native --flavour=default+native_bignum+late_ccs --docs=none \
  2>&1 | tee build-native.log
```

`late_ccs` builds the profiled libraries with `-fprof-late`, as upstream's
`perf` flavour does. Without it, profiles and profiling call stacks contain no
cost centres from `base` (e.g. `GHC.Internal.TopHandler.runMainIO`), and about
10 profiling tests fail with `bad profile` or `bad stdout`. Adding it to an
existing build rebuilds only the profiled libraries. This fix is inferred from
how Hadrian's flavours differ and hasn't been tested yet.

The empty `mingw` directory serves the same purpose as the one in section 5.
GHC on Windows refuses to start unless a `mingw` directory exists up to three
levels above its `lib` folder. Hadrian only creates `<build-root>/mingw` when
the distro toolchain is *off* (`hadrian/src/Builder.hs`). Without the
directory, the first in-tree compiler fails while configuring `libffi-clib`:
`_build-native/stage0/bin/ghc.exe … could not detect mingw toolchain`.
Recreate it if you ever delete `_build-native`.

Pass the same `--build-root=_build-native` to every later Hadrian command
for this build.

If you ran the build before doing step 6.1, delete `_build-native` first
(`rm -rf _build-native`), then recreate `_build-native/mingw`. Hadrian doesn't redo package copies it already made,
so stale copies with the unexpanded `${pkgroot}` would remain.

### 6.5 Check the result

The native compiler is `_build-native/stage1/bin/ghc.exe` (Hadrian's stage1
directory holds the stage2 compiler):

```bash
G=_build-native/stage1/bin/ghc.exe
$G -e 1+2                                   # 3
$G -e 'sum [1..100 :: Integer]'             # 5050
```

To run the testsuite, use the same Hadrian flags and add `test`. Use
`--only="name1 name2"` to run individual tests:

```bash
hadrian/build -j --build-root=_build-native --flavour=default+native_bignum+late_ccs --docs=none test
```

Run it from a terminal (the MSYS2 CLANGARM64 window). The testsuite driver
stops with *"Can't detect Windows terminal type"* when it has no console.

---

## 7. Known limitations

- **No GHCi or Template Haskell in the stage3 compiler.** A GHC built by a
  cross-compiler has no internal interpreter, so `ghc -e` and `ghci` report
  *"not built for interactive use"*. `ghc-iserv` isn't part of the cross
  build's stage2 package set. Use the native build from section 6 instead.
- **The ARM64 RTS linker support is new** (section 2) and covered only by
  the testsuite. The `SECTION` relocation (debug info) isn't implemented.
  Loaded objects can be relocated against thread-local variables (`SECREL*`),
  but the linker doesn't set up thread-local storage for them, so that code
  must not actually touch those variables. This matches x86_64. A far
  reference to *data* in a DLL (more than about 3GB from `ghc.exe`) is
  reported as an error rather than redirected. Taking the address of a DLL
  function from loaded code yields a jump island, so that address can differ
  between objects.
- **Hand-written Cmm that uses `STK_CHK_GEN_N` in a procedure without an info
  table doesn't assemble** (testsuite `T9329`):
  `assembler label '.Lc6_info' can not be undefined`. Without
  tables-next-to-code, which Windows ARM64 doesn't use, GHC only emits an info
  table for a procedure's own entry. Haskell code and the RTS's own Cmm aren't
  affected. Unregisterised builds, which also lack tables-next-to-code, have
  this test marked as broken.
- No documentation is built (`--docs=none`; Sphinx isn't installed).
- Sections 1–5 were validated with the commands above. Section 6 is
  validated as described in its status note. None of this is covered by
  upstream CI.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `This GHC … does not generate code for the build platform` | Pass `--build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32`. |
| `machine type x64 conflicts with arm64` during configure | Missing `--enable-distro-toolchain`. |
| `The path to builder 'cc' … is an MSYS path` | Environment variables used `/c/…`. Use `C:/…` and re-run configure. |
| `Error, file does not exist and no rule available: sys/types.h` | The stage0 `--target` fix (section 2) is missing. Run `python3 boot`, then configure again. |
| `Missing (or bad) C library: rt` | The `UseLibrtHost` fix (section 2) is missing. |
| `builderMainLoop: invalid argument` linking `unlit` | The host windres fix (section 2) is missing. |
| `Cannot combine instructions: … Long 241 …` from hsc2hs | The hsc2hs `ATTParser` fix (section 2) is missing. |
| `commitBuffer: invalid argument (cannot encode character …)` | Run `chcp.com 65001` before building. |
| `could not detect mingw toolchain` when running the installed GHC | Create the empty `mingw` directory (section 5). |
| `_build-native/stage0/bin/ghc.exe … could not detect mingw toolchain` | `mkdir -p _build-native/mingw`, then build again (section 6.4). |
| `no rule available: binary-dist-dir-stage3` | Use the `stage3:exe:*` targets (section 4.4). |
| `… is a development snapshot of GHC …` from configure | Add `--enable-bootstrap-with-devel-snapshot` (section 6.3). |
| `Could not resolve dependencies … hashable => base … <4.23` | Create `hadrian/cabal.project.local` (section 6.2). |
| `Could not load module 'GHC.Num.BigNat'` building hashable | The `package hashable` stanza in `hadrian/cabal.project.local` is missing (section 6.2). |
| `panic! … Invalid platform constants` compiling `utils/unlit/unlit.c` | The native build reused the cross build's `_build`. Use `--build-root=_build-native` (section 6.4). |
| `PE/PE+ not supported on ARM64.` from `ghc -e` or `ghci` | The RTS linker fix (section 2) is missing. |
| `unknown symbol '$L.text_1'` when GHCi loads `libHSghc-internal` | The `IMAGE_SYM_CLASS_LABEL` part of the RTS linker fix (section 2) is missing. |
| Thousands of testsuite failures, mostly `[stderr mismatch]`, with source snippets (`8 \| …` and `^^^`) in the actual output | The `RunTest.hs` fix (section 2) is missing. |
| `Can't detect Windows terminal type` from the testsuite | Run Hadrian's `test` from a terminal window (section 6.5). |
| SIMD tests print huge or garbage values in the first lanes of a vector | The `AArch64/Ppr.hs` fix (section 2) is missing. |
| `unhandled ARM64 PEi386 relocation type 0xa` loading `libc++abi.a` | The `SECREL*` part of the RTS linker fix (section 2) is missing. |
| Profiling tests miss cost centres such as `runMainIO` or `$fTraversable…` | Build with the `late_ccs` flavour transformer (section 6.4). |
| `lld: error: unable to find library -lHS…-inplace` in the native build | Apply step 6.1, then `rm -rf _build-native && mkdir -p _build-native/mingw` and build again. |
