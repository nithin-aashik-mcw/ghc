# Build GHC on Windows ARM64: quick steps

These steps build a native Windows ARM64 GHC on a Windows ARM64 machine. For
background and troubleshooting, see `BUILD-WINDOWS-ARM64.md`.

There is no released Windows ARM64 GHC to start from, so the build has two
stages. Step 2 uses the x86_64 GHC, running under emulation, to make a
temporary ARM64 compiler. Step 3 uses that compiler to build GHC natively, in
the same way as the x86_64 Windows build.

## What you need

- A Windows 11 ARM64 machine with about 40 GB free disk space. The full build
  takes about 4 hours.
- MSYS2 installed in `C:\msys64`.
- The **x86_64 Windows** GHC bindist, version 9.10 or newer, unpacked so that
  `C:\msys64\opt\ghc\bin\ghc.exe` exists.
- The **x86_64 Windows** `cabal.exe`, version 3.14 or newer, in
  `C:\msys64\opt\cabal`.
- This GHC source tree, with submodules
  (`git submodule update --init --recursive`).

Run every command in the **MSYS2 CLANGARM64** shell, from the top of the GHC
source tree. Steps 2 and 3 each start in a **new** shell.

## Step 1: Install the tools (one time)

```bash
pacman -S --needed --noconfirm git tar unzip patch make autotools \
  mingw-w64-clang-aarch64-python mingw-w64-clang-aarch64-toolchain \
  mingw-w64-clang-aarch64-lld mingw-w64-clang-aarch64-llvm

export PATH=/opt/ghc/bin:/opt/cabal:$PATH
cabal update
cabal install alex happy --constraint='happy<2.3' \
  --install-method=copy --overwrite-policy=always \
  --installdir="$(cygpath -m ~/.local/bin)"
```

## Step 2: Build the temporary ARM64 compiler (about 2 hours)

Open a new CLANGARM64 shell and go to the GHC source tree.

```bash
chcp.com 65001 > /dev/null
export PATH=/opt/ghc/bin:/opt/cabal:$HOME/.local/bin:$PATH

# Make GHC's bundled ARM64 toolchain (clang/LLVM 20, the same versions as
# GHC's x86_64 one). Steps 2 and 3 both use it.
mk/make-win32-tarballs.sh aarch64 ~/ghc-mingw-mirror

# Unpack it for the temporary compiler in C:\ghc-arm64-boot\mingw.
B=/c/ghc-arm64-boot
rm -rf $B && mkdir -p $B
for p in ~/ghc-mingw-mirror/aarch64/*.pkg.tar.zst; do tar --zstd -xf $p -C $B; done
rm -f $B/.MTREE $B/.PKGINFO $B/.BUILDINFO $B/.INSTALL
mv $B/clangarm64 $B/mingw

# Use it as the ARM64 toolchain. Use C:/ paths, not /c/ paths.
T=C:/ghc-arm64-boot/mingw/bin
export CC=$T/clang.exe CXX=$T/clang++.exe LD=$T/ld.lld.exe \
       AR=$T/llvm-ar.exe NM=$T/llvm-nm.exe RANLIB=$T/llvm-ranlib.exe \
       OBJDUMP=$T/llvm-objdump.exe STRIP=$T/llvm-strip.exe \
       WindresCmd=$T/llvm-windres.exe DlltoolCmd=$T/llvm-dlltool.exe \
       LLC=$T/llc.exe OPT=$T/opt.exe LLVMAS=$T/clang.exe MergeObjsCmd=""
F="--rtlib=compiler-rt -D_UCRT"
export CFLAGS="$F" CONF_CC_OPTS_STAGE1="$F" CONF_CC_OPTS_STAGE2="$F"
export CONF_GCC_LINKER_OPTS_STAGE1="-fuse-ld=lld $F" CONF_GCC_LINKER_OPTS_STAGE2="-fuse-ld=lld $F"

python3 boot

# Fetch the x86_64 toolchain, then configure an x86_64 -> ARM64 cross-compiler.
./configure --build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32 \
  --enable-tarballs-autodownload GHC=$(which ghc)
./configure --build=x86_64-unknown-mingw32 --host=x86_64-unknown-mingw32 \
  --target=aarch64-unknown-mingw32 --enable-distro-toolchain --disable-numa \
  GHC=$(which ghc) ALEX=$(which alex) HAPPY=$(which happy)

# Build the cross-compiler, then use it to build ARM64 programs.
hadrian/build -j --flavour=default+native_bignum --docs=none binary-dist-dir
hadrian/build -j --flavour=default+native_bignum --docs=none \
  stage3:exe:ghc-bin stage3:exe:ghc-pkg stage3:exe:unlit stage3:exe:hsc2hs
```

Install the temporary compiler in `C:\ghc-arm64-boot`:

```bash
cp -r _build/stage2/bin _build/stage2/lib $B/
cp $B/bin/unlit.exe $B/bin/aarch64-unknown-mingw32-unlit.exe

# Work around a ghc-pkg bug in this compiler: use absolute library paths.
W=$(cygpath -m $B/lib)
sed -i "/^library-dirs-static:/{n;s|[\$]{pkgroot}|$W|}" $B/lib/package.conf.d/*.conf
$B/bin/ghc-pkg.exe recache

$B/bin/ghc.exe --info | grep 'Host platform'   # aarch64-unknown-mingw32
```

## Step 3: Build GHC natively (about 2 hours)

Open a new CLANGARM64 shell and go to the GHC source tree. Don't reuse the
shell from step 2: its toolchain settings must not leak into this build.

```bash
chcp.com 65001 > /dev/null
export PATH=/opt/ghc/bin:/opt/cabal:$HOME/.local/bin:$PATH

# Use the ARM64 toolchain made in step 2.
export GHC_WIN32_TARBALLS_MIRROR=~/ghc-mingw-mirror

# The same configure and build commands as on x86_64.
./configure --enable-tarballs-autodownload --enable-bootstrap-with-devel-snapshot \
  GHC=/c/ghc-arm64-boot/bin/ghc.exe
hadrian/build -j --build-root=_build-native --flavour=default+native_bignum \
  --docs=none binary-dist
```

`ghc` on `PATH` is still the x86_64 GHC. Hadrian builds itself with it,
while GHC is built with the ARM64 compiler given to `configure`.

## Step 4: Install and check

```bash
rm -rf /c/ghc-arm64 && mkdir -p /c/ghc-arm64
tar -xf _build-native/bindist/ghc-*-aarch64-unknown-mingw32.tar.xz \
  -C /c/ghc-arm64 --strip-components=1

G=/c/ghc-arm64/bin/ghc.exe
$G --info | grep 'Host platform'      # aarch64-unknown-mingw32
$G -e 'sum [1..100 :: Integer]'       # 5050
echo 'main = putStrLn "hello from ARM64"' > hello.hs
$G hello.hs -o hello.exe && ./hello.exe
```

`C:\ghc-arm64` is self-contained. Add `C:\ghc-arm64\bin` to `PATH` to use
it. You can delete `C:\ghc-arm64-boot` now.
