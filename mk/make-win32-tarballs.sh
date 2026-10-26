#!/usr/bin/env bash
# Build the bundled aarch64 Windows toolchain, which downloads.haskell.org
# doesn't publish, in the layout mk/get-win32-tarballs.py expects:
#
#   <out-dir>/aarch64/MANIFEST
#   <out-dir>/aarch64/SHA256SUMS
#   <out-dir>/aarch64/*.pkg.tar.zst
#
# It holds the aarch64 builds of exactly the MSYS2 packages, at exactly the
# versions, in GHC's x86_64 bundle (e.g. LLVM 20.1.7). They come from
# repo.msys2.org and are checked against MSYS2's signing keys. Pinning matters:
# clang >= 21 emits CodeView records into .debug$S even without -g, which
# hsc2hs --via-asm (used when cross-compiling to Windows) can't parse.
#
# Run it from an MSYS2 shell, then point configure at the result with
# GHC_WIN32_TARBALLS_MIRROR=<out-dir>.
#
# Usage: mk/make-win32-tarballs.sh aarch64 <out-dir>

set -euo pipefail

arch="${1:?usage: $0 aarch64 <out-dir>}"
out="${2:?usage: $0 aarch64 <out-dir>}"
[ "$arch" = aarch64 ] || { echo "only aarch64 is supported" >&2; exit 1; }

top="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n "s/^TARBALL_VERSION = '\(.*\)'/\1/p" "$top/mk/get-win32-tarballs.py")"
x86_manifest="https://downloads.haskell.org/ghc/mingw/$version/x86_64/MANIFEST"
repo="https://repo.msys2.org/mingw/clangarm64"

dest="$out/$arch"
mkdir -p "$dest"
cd "$dest"

files=$(curl -fsSL "$x86_manifest" | sed 's/^mingw-w64-clang-x86_64-/mingw-w64-clang-aarch64-/')

# Remove packages from an earlier, different, version of the bundle: configure
# extracts every package in the directory.
for f in *.pkg.tar.*; do
  [ -e "$f" ] || continue
  grep -qxF "$f" <<< "$files" || rm -f "$f"
done

for f in $files; do
  if [ ! -f "$f" ]; then
    echo "Fetching $f"
    curl -fsSL -o "$f.part" "$repo/$f"
    mv "$f.part" "$f"
  fi
  curl -fsSL -o "$f.sig" "$repo/$f.sig"
  # gpgv only reads pacman's keyring, so unlike `pacman-key --verify` it
  # needs no write access to it.
  if ! gpgv --keyring /etc/pacman.d/gnupg/pubring.gpg "$f.sig" "$f" > /dev/null 2>&1; then
    echo "Bad signature: $f" >&2
    exit 1
  fi
  rm -f "$f.sig"
done

# N.B. get-win32-tarballs.py splits MANIFEST on '\n', so no trailing newline.
printf '%s\n' $files | head -c -1 > MANIFEST
sha256sum $files > SHA256SUMS
echo "Wrote $(wc -w <<< "$files") packages to $dest"
