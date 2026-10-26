#!/usr/bin/env python
# -*- coding: utf-8 -*-

from pathlib import Path
import urllib.request
import subprocess
import argparse
import os
import sys
from sys import stderr

TARBALL_VERSION = '0.9'
BASE_URL = "https://downloads.haskell.org/ghc/mingw/{}".format(TARBALL_VERSION)
DEST = Path('ghc-tarballs/mingw-w64')
# Architectures fetched by 'all' (e.g. for source distributions).
ARCHS = ['x86_64', 'sources']
# aarch64 isn't published on downloads.haskell.org; it must come from a mirror
# made with mk/make-win32-tarballs.sh (see BUILD-WINDOWS-ARM64.md).
EXTRA_ARCHS = ['aarch64']

# GHC_WIN32_TARBALLS_MIRROR overrides BASE_URL. It may be a URL or a local
# directory with the same layout (<arch>/MANIFEST, <arch>/SHA256SUMS, ...).
mirror = os.environ.get('GHC_WIN32_TARBALLS_MIRROR')
if mirror:
    BASE_URL = mirror if '://' in mirror else Path(mirror).resolve().as_uri()

def file_url(arch: str, fname: str) -> str:
    return "{base}/{arch}/{fname}".format(
        base=BASE_URL,
        arch=arch,
        fname=fname)

def fetch(url: str, dest: Path):
    print('Fetching', url, '=>', dest, file=stderr)
    urllib.request.urlretrieve(url, dest)

def fetch_arch(arch: str):
    manifest_url = file_url(arch, 'MANIFEST')
    print('Fetching', manifest_url, file=stderr)
    req = urllib.request.urlopen(manifest_url)
    files = req.read().decode('UTF-8').split('\n')
    d = DEST / arch
    if not d.is_dir():
        d.mkdir(parents=True)
    fetch(file_url(arch, 'SHA256SUMS'), d / 'SHA256SUMS')
    for fname in files:
        if not (d / fname).is_file():
            fetch(file_url(arch, fname), d / fname)

    verify(arch)

def list_arch(arch: str):
    d = DEST / arch
    manifest_url = file_url(arch, 'MANIFEST')
    req = urllib.request.urlopen(manifest_url)
    files = req.read().decode('UTF-8').split('\n')
    print(d / 'SHA256SUMS')
    for fname in files:
      print(d / fname)

def verify(arch: str):
    if not Path(DEST / arch / "SHA256SUMS").is_file():
        print("SHA256SUMS doesn't exist; have you fetched?", file=stderr)
        sys.exit(2)

    cmd = ['sha256sum', '--quiet', '--check', '--ignore-missing', 'SHA256SUMS']
    subprocess.check_call(cmd, cwd=DEST / arch)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['verify', 'download', 'list'])
    parser.add_argument(
        'arch',
        choices=ARCHS + EXTRA_ARCHS + ['all'],
        help="Architecture to fetch (either x86_64, aarch64, sources, or all)")
    args = parser.parse_args()

    action = { 'download' : fetch_arch, 'verify' : verify, 'list' : list_arch }[args.mode]
    if args.arch == 'all':
        for arch in ARCHS:
            action(arch)
    else:
        action(args.arch)

if __name__ == '__main__':
    main()
