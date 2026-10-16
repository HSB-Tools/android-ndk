#!/usr/bin/env bash
# Rebuild the sysroot's arc4random.o from bionic main and splice it back into
# libc.a, so `-static` programs stop aborting on kernels without
# MADV_WIPEONFORK and regain real fork semantics.
#
#   ./rebuild-arc4random.sh [cc] [cc2 ...]
#
# Each argument is a clang wrapper (aarch64-linux-android24-clang, ...) and its
# own directory is taken as the toolchain bin dir. With no argument the NDK is
# discovered: $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT / $NDK_HOME / $ANDROID_NDK
# first, then the usual SDK install locations, newest version first. The host
# prebuilt dir (linux-x86_64, linux-arm64, darwin-x86_64, ...) is whichever one
# that NDK actually ships, so nothing here is pinned to a version, a host
# triplet, or an install prefix. Every ABI the NDK has a wrapper for gets
# patched; pass explicit wrappers to patch a subset.
#
# The NDK's own build does not need this script: scripts/make-ndk.sh calls
# splice_arc4random() with $NDK_TOOLCHAIN, which setup_toolchain() derives from
# the build. This is the path for an already-installed NDK.
#
# src/ holds the bionic `main` sources (arc4random.c, arc4random.h,
# chacha_private.h) -- byte-identical to android.googlesource.com/platform/bionic
# and re-fetchable from there when upstream moves. All build objects land in a
# scratch dir, never in this tree.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CCS=()
[ -d "$HERE/src" ] || {
  echo "missing $HERE/src (fetch arc4random.c / arc4random.h / chacha_private.h first)" >&2
  exit 1
}

# Toolchain bin dir of a candidate NDK root: the prebuilt host dir that actually
# carries the clang wrappers. Prints it, or returns non-zero.
prebuilt_bin_of() {
  local root="$1" host found
  [ -n "$root" ] || return 1
  for host in "$root"/toolchains/llvm/prebuilt/*/bin; do
    if [ -d "$host" ]; then
      found="$(ls "$host"/aarch64-linux-android*-clang 2>/dev/null | head -n1)"
      if [ -n "$found" ]; then
        printf '%s\n' "$host"
        return 0
      fi
    fi
  done
  return 1
}

if [ $# -gt 0 ]; then
  # Wrappers given: patch exactly those. Resolve a bare name through PATH so
  # `rebuild-arc4random.sh aarch64-linux-android24-clang` works.
  CCS=()
  for w in "$@"; do
    case "$w" in
      */*) CCS+=("$w") ;;
      *)   CCS+=("$(command -v "$w" || { echo "not found: $w" >&2; exit 1; })") ;;
    esac
  done
  BIN="$(cd "$(dirname "${CCS[0]}")" && pwd)"
else
  BIN=""
  # An explicit root is how a user pins one NDK, so it wins outright.
  for root in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${NDK_HOME:-}" "${ANDROID_NDK:-}"; do
    if [ -n "$root" ]; then
      BIN="$(prebuilt_bin_of "$root" || true)"
      if [ -n "$BIN" ]; then break; fi
    fi
  done

  if [ -z "$BIN" ]; then
    roots=()
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
      if [ -n "$sdk" ]; then
        for d in "$sdk"/ndk/*; do
          if [ -d "$d" ]; then roots+=("$d"); fi
        done
      fi
    done
    for d in "$HOME"/.local/opt/android-sdk/ndk/* "$HOME"/Android/Sdk/ndk/* \
             "$HOME"/.local/opt/android-ndk-* /opt/android-sdk/ndk/* \
             /opt/android-ndk-* /usr/lib/android-sdk/ndk/*; do
      if [ -d "$d" ]; then roots+=("$d"); fi
    done

    if [ ${#roots[@]} -eq 0 ]; then
      echo "no NDK found: set ANDROID_NDK_HOME, or pass a clang wrapper path" >&2
      exit 1
    fi

    # Newest version first, when the host sort understands version ordering.
    if printf 'x\n' | sort -V >/dev/null 2>&1; then
      sorted=()
      while IFS= read -r d; do sorted+=("$d"); done \
        < <(printf '%s\n' "${roots[@]}" | sort -Vr)
      roots=("${sorted[@]}")
    fi

    for root in "${roots[@]}"; do
      BIN="$(prebuilt_bin_of "$root" || true)"
      if [ -n "$BIN" ]; then break; fi
    done
  fi

  if [ -z "$BIN" ]; then
    echo "found NDK roots but no toolchains/llvm/prebuilt/*/bin with clang wrappers" >&2
    exit 1
  fi
  echo "toolchain: $BIN"
fi

# With no explicit wrappers, take one per ABI at the lowest API level: the
# sysroot libc.a is per-ABI, not per-API, so any level resolves the same
# archive. Explicit wrappers were already collected above and are used as-is.
if [ ${#CCS[@]} -eq 0 ]; then
  for a in aarch64-linux-android armv7a-linux-androideabi i686-linux-android \
           x86_64-linux-android riscv64-linux-android; do
    for c in "$BIN/$a"*-clang; do
      if [ -x "$c" ]; then CCS+=("$c"); break; fi
    done
  done
fi
if [ ${#CCS[@]} -eq 0 ]; then
  echo "no clang wrappers in $BIN" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arc4random-splice.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=splice-core.sh
. "$HERE/splice-core.sh"
arc4_splice_work_init "$WORK" "$HERE"

for CC in "${CCS[@]}"; do
  # Derive the per-ABI lib dir from the wrapper's own name (strip -clang, then
  # the API digits): aarch64-linux-android24-clang -> aarch64-linux-android,
  # armv7a-linux-androideabi24-clang -> arm-linux-androideabi. Asking clang
  # with --print-file-name=libc.a is not reliable -- it prints the bare string
  # "libc.a" for an Android target -- so build the sysroot path directly.
  ABI="$(basename "$CC")"; ABI="${ABI%-clang}"
  # strip the API level, which can be one digit or two (android21 ... android37)
  while case "$ABI" in *[0-9]) true ;; *) false ;; esac; do ABI="${ABI%?}"; done
  case "$ABI" in
    armv7a-linux-androideabi) LIBDIR=arm-linux-androideabi ;;
    *)                        LIBDIR="$ABI" ;;
  esac
  LIBC="$BIN/../sysroot/usr/lib/$LIBDIR/libc.a"
  [ -f "$LIBC" ] || { echo "$CC: no libc.a at $LIBC" >&2; exit 1; }
  echo "==> $CC -> $LIBC"

  arc4_splice_abi "$CC" "$LIBC" "$WORK" \
    || { echo "$CC: splice failed" >&2; exit 1; }
  echo "    spliced arc4random.o into $LIBC"
done
