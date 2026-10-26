# Building GHC for Windows ARM64 (aarch64) with MSYS2

This guide builds a **native Windows ARM64 GHC**, with GHCi and Template
Haskell, on a Windows ARM64 machine (tested on a Snapdragon X / SC8380XP,
Windows 11). The main build (Part B) uses the same steps as the x86_64
Windows build in upstream CI: `configure --enable-tarballs-autodownload`, then
`hadrian/build binary-dist`.

Building GHC needs an existing GHC for the same platform, and no official
Windows ARM64 GHC has been released. The guide therefore has two parts:

- **Part A — bootstrap compiler (one time).** The official x86_64 Windows GHC,
  running under Windows' x64 emulation, builds a cross-compiler
  (x86_64 host, `aarch64-unknown-mingw32` target). That cross-compiler then
  builds a native ARM64 `ghc.exe`. This compiler has no GHCi and is only
  used to start Part B.
- **Part B — native build.** The Part A compiler builds GHC natively and
  produces a self-contained bindist.

If you already have an ARM64 Windows GHC, either a release or one from an
earlier Part B build, skip Part A apart from A.1.

Both parts use GHC's bundled toolchain for ARM64 (clang, lld and the MinGW-w64
runtime), at the same versions as GHC's x86_64 one: LLVM 20.1.7.
downloads.haskell.org doesn't publish it, so A.1 makes it from MSYS2's
packages.

Compared with the x86_64 build:

| | x86_64 (upstream CI) | aarch64 (Part B) |
|---|---|---|
| MSYS2 shell | `CLANG64` | `CLANGARM64` |
| Bootstrap GHC | released x86_64 bindist | ARM64 GHC from Part A |
| Toolchain | bundled, downloaded from downloads.haskell.org | bundled, from a mirror you make (A.1) |
| Configure | `./configure --enable-tarballs-autodownload GHC=…` | the same, plus `--enable-bootstrap-with-devel-snapshot` (see B.2) |
| Build | `hadrian/build binary-dist` | the same |
| Bignum | GMP | `native_bignum` (GMP untested) |

Tested against GHC `10.1` (master at `f217fc315b`). Windows ARM64 support first
appeared in the 9.14 release line.

---

## 1. Prerequisites

### MSYS2 packages

Open the **MSYS2 CLANGARM64** shell and run:

```bash
pacman -Syu        # repeat until nothing is left to update
pacman -S --needed git tar unzip patch make autotools \
  mingw-w64-clang-aarch64-python \
  mingw-w64-clang-aarch64-toolchain mingw-w64-clang-aarch64-lld \
  mingw-w64-clang-aarch64-llvm
```

Use the clangarm64 Python rather than the MSYS one: like upstream CI, this
avoids the path-length problems in GHC issue #17483.

The build doesn't use MSYS2's own clangarm64 compiler, which follows MSYS2's
current LLVM. It uses the pinned toolchain from A.1 instead, because clang 21
and newer break hsc2hs when cross-compiling (see section 2).

### Bootstrap tools (x86_64)

| Tool | Version used | Location used in this guide |
|---|---|---|
| GHC (x86_64-unknown-mingw32 bindist) | 9.12.3 (≥ 9.10 required) | `/opt/ghc-9.12.3` |
| cabal-install (x86_64 Windows) | 3.14+ | `/opt/cabal` |
| alex / happy | 3.5.4.2 / 2.2 | `~/.local/bin` (via `cabal install alex happy`) |

These x86_64 programs run under emulation. cabal-install, alex and happy are
used in both parts; there is no ARM64 Windows cabal-install release.

### Source

```bash
git clone --recursive <your ghc repo> ~/Project/ghc
cd ~/Project/ghc
git submodule update --init --recursive
```

All commands in this guide run from `~/Project/ghc` in a CLANGARM64 shell.

---

## 2. Source changes

Upstream only tests Windows ARM64 as a cross-compile **from Linux**. Building
on Windows needs the changes below, which are in this working tree:

| File | Problem | Fix |
|---|---|---|
| `configure.ac`, `m4/fp_cc_supports_target.m4`, `m4/fp_prog_cc_linker_target.m4` | The stage0 (host) C compiler was given `--target=aarch64-…` instead of the build platform's triple. A clang host compiler then can't find its own headers: `Error … no rule available: sys/types.h`. | Stage0 checks now use `$LlvmBuildTarget`, computed from `$build`. |
| `configure.ac`, `hadrian/cfg/system.config.host.in` | `use-lib-rt = YES` was hardcoded for the host, which fails on Windows: `Missing (or bad) C library: rt`. | New `@UseLibrtHost@`: `NO` on mingw32/darwin hosts. |
| `configure.ac`, `m4/prep_target_file.m4`, `hadrian/cfg/default.host.target.in` | The host target had no windres, so the stage1 compiler failed to link any executable: `builderMainLoop: invalid argument`. An empty merge-objects command became `"."`. | windres comes from the bootstrap GHC's `--info`. Merge-objects is `Nothing` when empty. |
| `m4/fp_setup_windows_toolchain.m4`, `mk/get-win32-tarballs.py`, `mk/make-win32-tarballs.sh` (new) | The bundled Windows toolchain (`--enable-tarballs-autodownload`) only supported x86_64, and downloads.haskell.org publishes no aarch64 toolchain. | configure sets up the `clangarm64` toolchain for an aarch64 host. `make-win32-tarballs.sh` makes it from the aarch64 builds of the MSYS2 packages in the x86_64 one, at the same versions, and `GHC_WIN32_TARBALLS_MIRROR` points configure at it. `inplace/mingw/.ghc-mingw-arch` records the extracted architecture, so configure replaces `inplace/mingw` when you switch between Part A (x86_64) and Part B (aarch64). |
| `.gitlab/ci.sh`, `.gitlab/generate-ci/gen_ci.hs`, `.gitlab/jobs.yaml` | No Windows ARM64 CI. | Windows ARM64 jobs; see B.7. |
| `utils/ghc-pkg/Main.hs` | `ghc-pkg describe --expand-pkgroot` didn't expand `${pkgroot}` in `library-dirs-static`. Hadrian copies the bootstrap compiler's packages this way, so static links searched the wrong directory: `lld: error: unable to find library -lHSbase-…`. Only matters in Part B. | `mungePackagePaths` now expands `libraryDirsStatic` too, like GHC's own `mungeUnitInfoPaths`. |
| `rts/linker/PEi386.c`, `rts/linker/PEi386Types.h` | GHCi's object loader had only placeholder ARM64 support, so `ghc -e`, `ghci` and Template Haskell failed with `PE/PE+ not supported on ARM64.` | Implements the ARM64 COFF relocations, jump islands for far targets (see `Note [ARM64 jump islands]`), `.pdata` registration and instruction-cache flushing. Also treats `IMAGE_SYM_CLASS_LABEL` symbols (LLVM's `$L.text_N`) as local, and handles the `SECREL*` relocations that `libc++abi` uses for thread-local variables. |
| `compiler/GHC/CmmToAsm/AArch64/Ppr.hs` | The ARM64 code generator printed a literal's `.p2align` *after* its label. For 16-byte SIMD constants that follow code in `.text`, the label could end up pointing at `nop` padding, so the low half of the vector was garbage (e.g. `-3097596797610942433` = two `nop`s). | Aligns the label for the most strictly aligned item it labels. |
| `hadrian/src/Settings/Builders/RunTest.hs` | `ifMinGhcVer` compared versions as strings, so with a 10.x bootstrap compiler (`"1001"` < `"801"`) the testsuite ran without `-fno-diagnostics-show-caret` and three other flags. About 3,400 tests failed with `stderr mismatch`. | Compares the versions as numbers. |
| `linters/lint-codes/LintCodes/Coverage.hs` | The `codes` test failed with `C:\home\…\testsuite\tests: … does not exist`. MSYS git returns `/home/user/ghc` for a checkout inside the MSYS root, which Windows programs can't resolve. | Gets the tree root with `git rev-parse --show-cdup` (a relative path) instead. |
| Tests: `ghci/should_run/T25636f`, `ghc-heap/tests/create_tso.c`, `rts/T7289` | Two tests assumed tables-next-to-code, and `T7289` reads the x87 FPU control word. | Pass the right info-table layout; skip `T7289` on non-x86. |
| `testsuite/tests/codeGen/should_run/all.T` | `CallConv`'s assembly only works with tables-next-to-code, which Windows ARM64 doesn't use. It crashed with *"Access violation … when executing data"*. | Skip the test without tables-next-to-code. |

**hsc2hs needs no change.** When cross-compiling to Windows (Part A), hsc2hs
reads constants from assembly that the C compiler generates (`--via-asm`).
clang 21 and newer always add CodeView records to that assembly, in a
`.debug$S` section, even without `-g`, and no flag turns them off. hsc2hs
can't parse them: `Cannot combine instructions: [Quad 4,Long 4,Long 241,…]`.
The pinned toolchain from A.1 is LLVM 20.1.7, which doesn't emit them. Part B
is a native build and doesn't use `--via-asm`.

After changing `configure.ac` or anything in `m4/`, regenerate `configure` with
`python3 boot`.

---

## Part A — Bootstrap compiler (one time)

### A.1 Make the bundled ARM64 toolchain

```bash
mk/make-win32-tarballs.sh aarch64 ~/ghc-mingw-mirror
```

This makes the toolchain that GHC bundles on Windows, for ARM64. It contains
the aarch64 builds of the 20 MSYS2 packages in GHC's x86_64 bundle (clang,
lld, LLVM, compiler-rt, libc++, libunwind, the MinGW-w64 CRT and headers,
libffi, …), at exactly the same versions. The script reads the package list
from the x86_64 bundle's `MANIFEST` on downloads.haskell.org, downloads the
packages from repo.msys2.org, and checks their MSYS2 signatures with `gpgv`.
It writes `MANIFEST` and `SHA256SUMS` next to them, in the layout configure
expects, and doesn't change your MSYS2 installation.

Part A unpacks the toolchain next to the bootstrap compiler (A.2). Part B
reads it through `GHC_WIN32_TARBALLS_MIRROR` (B.3), which can also be an
`https://` URL: to give several machines the same toolchain, upload
`~/ghc-mingw-mirror` to a web server.

### A.2 Environment

Part A cross-compiles GHC. Its target toolchain is the bundle from A.1,
unpacked into the folder where the bootstrap compiler will be installed,
`C:\ghc-arm64-boot`:

```bash
B=/c/ghc-arm64-boot
rm -rf $B && mkdir -p $B
for p in ~/ghc-mingw-mirror/aarch64/*.pkg.tar.zst; do tar --zstd -xf $p -C $B; done
rm -f $B/.MTREE $B/.PKGINFO $B/.BUILDINFO $B/.INSTALL
mv $B/clangarm64 $B/mingw
```

GHC on Windows only starts if a `mingw` folder exists next to its `lib`
folder, so this also meets that requirement.

Put the following in a file (e.g. `~/ghc-arm64-cross-env.sh`) and `source` it
in every CLANGARM64 shell you use for Part A. Don't use it for Part B.

```bash
# GHC-built tools (hsc2hs) read/write files using the console code page.
# Sources contain UTF-8 (e.g. "μs"), so the default code page 437 breaks the build.
chcp.com 65001 > /dev/null

export PATH=/opt/ghc-9.12.3/bin:/opt/cabal:$HOME/.local/bin:$PATH

# Target (aarch64) toolchain from A.1. Use C:/ paths, NOT /c/ paths:
# GHC and Hadrian are native Windows programs and cannot resolve MSYS paths.
T=C:/ghc-arm64-boot/mingw/bin
export CC=$T/clang.exe CXX=$T/clang++.exe LD=$T/ld.lld.exe \
       AR=$T/llvm-ar.exe NM=$T/llvm-nm.exe RANLIB=$T/llvm-ranlib.exe \
       OBJDUMP=$T/llvm-objdump.exe STRIP=$T/llvm-strip.exe \
       WindresCmd=$T/llvm-windres.exe DlltoolCmd=$T/llvm-dlltool.exe \
       LLC=$T/llc.exe OPT=$T/opt.exe LLVMAS=$T/clang.exe MergeObjsCmd=""

F="--rtlib=compiler-rt -D_UCRT"
export CFLAGS="$F" CONF_CC_OPTS_STAGE1="$F" CONF_CC_OPTS_STAGE2="$F"
export CONF_GCC_LINKER_OPTS_STAGE1="-fuse-ld=lld $F" CONF_GCC_LINKER_OPTS_STAGE2="-fuse-ld=lld $F"
```

### A.3 Fetch the x86_64 host toolchain

The intermediate stage1 compiler runs on the x86_64 side and needs GHC's
bundled x86_64 toolchain in `inplace/mingw`. With `--enable-distro-toolchain`
(A.4), configure doesn't download it, so fetch it first with a plain native
x86_64 configure:

```bash
python3 boot
./configure --build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32 \
  --enable-tarballs-autodownload GHC=$(which ghc)
cat inplace/mingw/.ghc-mingw-arch  # x86_64
```

Part B replaces `inplace/mingw` with the aarch64 toolchain. If you come back
to Part A afterwards, repeat this step. Builds that already exist aren't
affected, because Hadrian keeps its own copy in `<build-root>/mingw`.

### A.4 Configure the cross build

```bash
./configure --build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32 \
  --target=aarch64-unknown-mingw32 --enable-distro-toolchain --disable-numa \
  GHC=$(which ghc) ALEX=$(which alex) HAPPY=$(which happy)
```

All of the following must hold:
- `--build` and `--host` are **x86_64**. If `--build` is left out, the
  CLANGARM64 shell makes autoconf guess `aarch64` and configure stops with
  *"This GHC … does not generate code for the build platform"*.
- `--enable-distro-toolchain` is passed. It makes configure use the target
  toolchain from A.2. Without it, configure replaces that toolchain with the
  bundled x86_64 one, and linking fails with
  *"machine type x64 conflicts with arm64"*.
- The summary shows `Target platform : aarch64-unknown-mingw32`.
- This command prints **nothing**. Any output means an MSYS path got in:

  ```bash
  grep -n '"/c/\|= /c/' hadrian/cfg/system.config hadrian/cfg/default*.target
  ```

### A.5 Build the cross-compiler and ARM64 libraries (~1h15m)

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

### A.6 Build the native ARM64 GHC (stage3)

```bash
hadrian/build -j --flavour=default+native_bignum --docs=none \
  stage3:exe:ghc-bin stage3:exe:ghc-pkg stage3:exe:unlit stage3:exe:hsc2hs
file _build/stage2/bin/*.exe          # all ARM64
```

(`binary-dist-stage3` can't be used: its rule is disabled in
`hadrian/src/Rules/BinaryDist.hs` as "Not working yet".)

### A.7 Install the bootstrap compiler

Copy the stage2 output next to its toolchain:

```bash
B=/c/ghc-arm64-boot
cp -r _build/stage2/bin _build/stage2/lib $B/

# The settings file names unlit with the cross prefix.
cp $B/bin/unlit.exe $B/bin/aarch64-unknown-mingw32-unlit.exe
```

Check:

```bash
$B/bin/ghc.exe --info | grep -E 'Host platform|Target platform'
#  ,("Host platform","aarch64-unknown-mingw32")
#  ,("Target platform","aarch64-unknown-mingw32")
$B/bin/ghc.exe -O hello.hs -o hello.exe && ./hello.exe
```

This compiler calls its toolchain in `C:\ghc-arm64-boot\mingw` by absolute
path, so it must stay in `C:\ghc-arm64-boot`. It has no GHCi or Template
Haskell (section 4).

---

## Part B — Native build

Use a **fresh** CLANGARM64 shell, without the Part A environment: configure
takes `CC`, `LD`, `CFLAGS` and the other toolchain settings from the bundled
toolchain itself.

```bash
chcp.com 65001 > /dev/null     # see A.2
export PATH=/opt/ghc-9.12.3/bin:/opt/cabal:$HOME/.local/bin:$PATH
```

`ghc` on `PATH` stays the x86_64 GHC. `hadrian/build` builds Hadrian itself
with it, while GHC is built with the ARM64 compiler given to configure (B.3).

### B.1 Fix the bootstrap package database (one time)

When Hadrian copies the bootstrap compiler's packages, `${pkgroot}` in
`library-dirs-static` can stay unexpanded, which makes every link fail with
`lld: error: unable to find library -lHS…-inplace`. The `ghc-pkg` fix in
section 2 addresses this, but this step is also needed for a bootstrap
compiler built without it. It is harmless otherwise. Write that field as an
absolute path in the bootstrap's own package files:

```bash
B=/c/ghc-arm64-boot
W=$(cygpath -m $B/lib)                                  # C:/ghc-arm64-boot/lib
cp -r $B/lib/package.conf.d $B/lib/package.conf.d.bak   # backup
sed -i "/^library-dirs-static:/{n;s|[\$]{pkgroot}|$W|}" $B/lib/package.conf.d/*.conf
$B/bin/ghc-pkg.exe recache
$B/bin/ghc-pkg.exe field base library-dirs-static       # must show C:/ghc-arm64-boot/lib\…
```

This changes only the `library-dirs-static` lines, one per package. To undo,
copy the backup back and run `ghc-pkg recache`.

### B.2 Bootstrapping from a development snapshot

The Part A compiler is a development snapshot (`10.1.x`), not a release, so
configure refuses it unless you pass `--enable-bootstrap-with-devel-snapshot`
(B.3).

If you build Hadrian with the snapshot itself rather than with the x86_64
GHC, its Hackage dependencies also fail with the snapshot's `base-4.23`:

- Every `hashable` release requires `base < 4.23`:
  `Could not resolve dependencies … hashable => base>=4.18.0.0 && <4.23`.
- `base-4.23` no longer exposes `GHC.Num.{BigNat,Integer,Natural}`
  (CLC proposal #359, see `libraries/base/changelog.md`), and hashable
  imports them: `Could not load module 'GHC.Num.BigNat' … hidden package 'ghc-bignum'`.

`hadrian/cabal.project.local`, committed in this tree, works around both.
cabal reads it automatically next to `hadrian/cabal.project`:

```cabal
-- Local workaround for bootstrapping with a GHC devel snapshot (base-4.23).
allow-newer: all

-- base-4.23 no longer exposes GHC.Num.{BigNat,Integer,Natural} (CLC #359).
package hashable
  ghc-options: -package ghc-bignum
```

With a **released** ARM64 GHC as the bootstrap, drop
`--enable-bootstrap-with-devel-snapshot`. The steps are then exactly the
x86_64 ones.

### B.3 Configure

The same command as x86_64, plus the devel-snapshot flag, with the mirror
from A.1:

```bash
export GHC_WIN32_TARBALLS_MIRROR=~/ghc-mingw-mirror
./configure --enable-tarballs-autodownload --enable-bootstrap-with-devel-snapshot \
  GHC=/c/ghc-arm64-boot/bin/ghc.exe
```

Upstream CI also passes `--enable-strict-ghc-toolchain-check`, which you can
add. Check that:

- the summary shows `aarch64-unknown-mingw32` for the build, host and target
  platforms;
- the C compiler is `…/inplace/mingw/bin/clang.exe`;
- the bundled toolchain is the aarch64 one:

  ```bash
  cat inplace/mingw/.ghc-mingw-arch   # aarch64
  file inplace/mingw/bin/clang.exe    # … ARM64
  ```

If `inplace/mingw` holds the x86_64 toolchain from A.3, configure replaces it
and prints *"Replacing the x86_64 toolchain in inplace/mingw with aarch64"*.

### B.4 Build

```bash
hadrian/build -j --build-root=_build-native --flavour=default+native_bignum+late_ccs \
  --docs=none binary-dist 2>&1 | tee build-native.log
```

Use a separate build root. `_build` holds Part A, whose stage0 package
database registers the x86_64 bootstrap compiler's `rts`, with x86_64
headers. Hadrian doesn't notice that the bootstrap compiler changed, so
reusing `_build` makes the ARM64 GHC fail with
`panic! (the 'impossible' happened) … Invalid platform constants`. A
separate build root also keeps Part A intact. Pass the same
`--build-root=_build-native` to every later Hadrian command for this build.

Hadrian copies the bundled toolchain into `_build-native/mingw` and includes
it in the bindist, as on x86_64.

If you built `_build-native` before doing B.1, delete it
(`rm -rf _build-native`) and build again. Hadrian doesn't redo package copies
it already made, so stale copies with the unexpanded `${pkgroot}` would
remain.

Flavour notes:

- `late_ccs` builds the profiled libraries with `-fprof-late`, as upstream's
  `perf` flavour does. Without it, profiles and profiling call stacks contain
  no cost centres from `base` (e.g. `GHC.Internal.TopHandler.runMainIO`), and
  about 10 profiling tests fail with `bad profile` or `bad stdout`. Adding it
  to an existing build rebuilds only the profiled libraries.
- x86_64 CI uses GMP (`--bignum=gmp`, built from the in-tree GMP sources)
  rather than `native_bignum`. Building GMP for aarch64 Windows hasn't been
  tried. To try it, drop `+native_bignum` and pass `--bignum=gmp`.
- x86_64 CI uses the `validate` flavour for merge requests and `release` for
  releases. Either can replace `default` above.

### B.5 Install and check

The bindist is written to `_build-native/bindist/`. As on x86_64, it is
self-contained: it carries its own toolchain and doesn't need MSYS2 at run
time. Unpack it anywhere:

```bash
mkdir -p /c/ghc-arm64
tar -xf _build-native/bindist/ghc-*-aarch64-unknown-mingw32.tar.xz \
  -C /c/ghc-arm64 --strip-components=1
G=/c/ghc-arm64/bin/ghc.exe
$G --info | grep -E 'Host platform|Target platform'   # aarch64-unknown-mingw32
$G -e 1+2                                             # 3
$G -e 'sum [1..100 :: Integer]'                       # 5050
$G -O hello.hs -o hello.exe && ./hello.exe
```

The compiler in the build tree, `_build-native/stage1/bin/ghc.exe` (Hadrian's
stage1 directory holds the stage2 compiler), works the same way.

This compiler can bootstrap later builds in place of the Part A one. It is
still a `10.1.x` development snapshot, so B.2 still applies.

### B.6 Run the testsuite

Use the same Hadrian flags and add `test`. Use `--only="name1 name2"` to run
individual tests:

```bash
hadrian/build -j --build-root=_build-native --flavour=default+native_bignum+late_ccs --docs=none test
```

Run it from a terminal (the MSYS2 CLANGARM64 window). The testsuite driver
stops with *"Can't detect Windows terminal type"* when it has no console.

### B.7 GitLab CI

`.gitlab/jobs.yaml` has two Windows ARM64 jobs, generated from
`windows_aarch64` in `.gitlab/generate-ci/gen_ci.hs`:

| Job | Runs |
|---|---|
| `aarch64-windows-int_native-validate` | In merge requests with both the `aarch64` and `Windows` labels, or when named in `ONLY_JOBS` |
| `nightly-aarch64-windows-int_native-validate` | In nightly pipelines |

Each job runs the same `ci.sh` steps as the `x86_64-windows-*` jobs, with
one extra step, `bootstrap_winarm64`, between `setup` and `configure`:

1. `setup` fetches the x86_64 GHC 9.10.3 and cabal-install, which run under
   emulation, and builds alex and happy.
2. `bootstrap_winarm64` makes the toolchain mirror (A.1) and the bootstrap
   compiler (A.2–A.7, in `ghc-arm64-boot/`) if they are missing, then
   applies B.1. GitLab caches both directories under the key
   `aarch64-windows-bootstrap-$CACHE_REV`, so only the first run, or a run
   after `CACHE_REV` is bumped, pays for Part A (about 2 hours). If the
   cache is restored in a different directory, the step points the bootstrap
   compiler at its toolchain's new location.
3. `configure` runs with the bootstrap compiler and
   `--enable-bootstrap-with-devel-snapshot`. Hadrian is built with the
   x86_64 GHC.
4. `build_hadrian` and `test_hadrian` build the bindist with the `validate`
   flavour and `native` bignum, and run the testsuite.

The runner needs:

- the tag `aarch64-windows`, and the shell executor running MSYS2 `bash`,
  as for the x86_64 Windows runners;
- MSYS2 with the section 1 packages, and access to downloads.haskell.org and
  repo.msys2.org;
- a job timeout of at least 6 hours for the first, uncached run.

Don't run `ci.sh setup` in your own checkout: it sets the repository's
`git config user.name` and `user.email` to the CI identity.

---

## 3. Validation status

- **Toolchain (A.1):** `make-win32-tarballs.sh` makes the mirror and rejects
  a tampered package. configure fetches, verifies and extracts it, and
  replaces an x86_64 `inplace/mingw`. The extracted clang 20.1.7 builds and
  runs ARM64 C and C++ programs with no MSYS2 directory on `PATH`.
- **hsc2hs:** unmodified hsc2hs, run as in Part A
  (`--cross-compile --via-asm`), produces correct ARM64 values with the pinned
  clang 20.1.7, and fails with `Cannot combine instructions` with MSYS2's
  clang 23.1.3.
- **Part A and B, earlier toolchain:** Part A, and a native build with GHCi
  and Template Haskell, were completed with MSYS2's clang 23.1.3 and a patched
  hsc2hs. A full testsuite run of the native build gave 11,865 expected passes
  and 26 unexpected failures. After the fixes in section 2, those 26 come
  down to `T9329` (section 4) and 10 profiling tests that `late_ccs` (B.4)
  is expected to fix.
- **Not yet run:** Parts A and B end to end with the pinned toolchain, the
  bindist install (B.5), and the `late_ccs` change.
- **CI (B.7):** the jobs are generated, `ci.sh` sets up the right environment
  under `MSYSTEM=CLANGARM64`, and the toolchain unpack and cache relocation
  steps were tested on their own. No job has run on a Windows ARM64 runner
  yet.

---

## 4. Known limitations

- **No GHCi or Template Haskell in the Part A compiler.** A GHC built by a
  cross-compiler has no internal interpreter, so `ghc -e` and `ghci` report
  *"not built for interactive use"*. `ghc-iserv` isn't part of the cross
  build's stage2 package set. Use the Part B compiler.
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
  `assembler label '.Lc6_info' can not be undefined`. In a procedure with no
  arguments, the stack check's slow path returns to the procedure's entry
  block. Without tables-next-to-code, which Windows ARM64 doesn't use, that
  entry block never gets an info table. Procedures with arguments return to a
  later block, which does get one, so Haskell code and the RTS's own Cmm aren't
  affected. The test is marked as broken for every build without
  tables-next-to-code, unregisterised builds included.
- **The aarch64 toolchain isn't published upstream.** You make it yourself
  (A.1) from MSYS2's archive. If the x86_64 bundle moves to LLVM 21 or newer,
  the cross build will need hsc2hs to ignore `.debug$S` (section 2).
- No documentation is built (`--docs=none`; Sphinx isn't installed).

---

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Bad signature: …` from `make-win32-tarballs.sh` | The package doesn't match MSYS2's signature, or your keyring is out of date. Run `pacman -Syu` (it updates `msys2-keyring`) and try again. |
| `This GHC … does not generate code for the build platform` in Part A | Pass `--build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32` (A.4). |
| `machine type x64 conflicts with arm64` during the Part A configure | Missing `--enable-distro-toolchain` (A.4). |
| `The path to builder 'cc' … is an MSYS path` | The A.2 environment used `/c/…`. Use `C:/…` and re-run configure. |
| `Error, file does not exist and no rule available: sys/types.h` | The stage0 `--target` fix (section 2) is missing. Run `python3 boot`, then configure again. |
| `Missing (or bad) C library: rt` | The `UseLibrtHost` fix (section 2) is missing. |
| `builderMainLoop: invalid argument` linking `unlit` | The host windres fix (section 2) is missing. |
| `Cannot combine instructions: … Long 241 …` from hsc2hs | Part A's C compiler is clang 21 or newer. Use the toolchain from A.1 (`T=C:/ghc-arm64-boot/mingw/bin`, A.2), not MSYS2's clangarm64. |
| `commitBuffer: invalid argument (cannot encode character …)` | Run `chcp.com 65001` before building. |
| `could not detect mingw toolchain` when running the Part A compiler | `C:\ghc-arm64-boot\mingw` is missing. Unpack the toolchain there (A.2). |
| `no rule available: binary-dist-dir-stage3` | Use the `stage3:exe:*` targets (A.6). |
| `HTTP Error 404` fetching `…/ghc/mingw/0.9/aarch64/MANIFEST` during configure | `GHC_WIN32_TARBALLS_MIRROR` isn't set. Export it (B.3). |
| `No bundled Windows toolchain for …; use --enable-distro-toolchain` | The host architecture has no bundled toolchain. Only x86_64 and aarch64 are supported. |
| `inplace/mingw/bin/clang.exe` is x86-64, or a different LLVM version than the mirror, after the Part B configure | `inplace/mingw` is left over from another toolchain. Delete `inplace/mingw` and `ghc-tarballs/mingw-w64/aarch64`, and configure again. |
| `… is a development snapshot of GHC …` from configure | Add `--enable-bootstrap-with-devel-snapshot` (B.3). |
| `Could not resolve dependencies … hashable => base … <4.23` | Hadrian is being built with the snapshot. Put the x86_64 GHC first on `PATH` (Part B), or restore `hadrian/cabal.project.local` (B.2). |
| `Could not load module 'GHC.Num.BigNat'` building hashable | As above. |
| `lld: error: unable to find library -lHS…-inplace` in Part B | Apply B.1, then `rm -rf _build-native` and build again. |
| `panic! … Invalid platform constants` compiling `utils/unlit/unlit.c` | Part B reused Part A's `_build`. Use `--build-root=_build-native` (B.4). |
| `PE/PE+ not supported on ARM64.` from `ghc -e` or `ghci` | The RTS linker fix (section 2) is missing. |
| `unknown symbol '$L.text_1'` when GHCi loads `libHSghc-internal` | The `IMAGE_SYM_CLASS_LABEL` part of the RTS linker fix (section 2) is missing. |
| `unhandled ARM64 PEi386 relocation type 0xa` loading `libc++abi.a` | The `SECREL*` part of the RTS linker fix (section 2) is missing. |
| SIMD tests print huge or garbage values in the first lanes of a vector | The `AArch64/Ppr.hs` fix (section 2) is missing. |
| Thousands of testsuite failures, mostly `[stderr mismatch]`, with source snippets (`8 \| …` and `^^^`) in the actual output | The `RunTest.hs` fix (section 2) is missing. |
| `Can't detect Windows terminal type` from the testsuite | Run Hadrian's `test` from a terminal window (B.6). |
| Profiling tests miss cost centres such as `runMainIO` or `$fTraversable…` | Build with the `late_ccs` flavour transformer (B.4). |
