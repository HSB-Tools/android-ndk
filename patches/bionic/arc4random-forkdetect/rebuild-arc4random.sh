#!/usr/bin/env bash
# Rebuild the sysroot's arc4random.o from bionic main and splice it back into
# libc.a, so `-static` programs stop aborting on kernels without
# MADV_WIPEONFORK and regain real fork semantics.
#
#   ./rebuild-arc4random.sh [cc] [cc2 ...]
#
# Each argument is a clang wrapper (aarch64-linux-android24-clang, …); with no
# argument every ABI the NDK ships is patched. src/ holds the bionic `main`
# sources (arc4random.c, arc4random.h, chacha_private.h) — byte-identical to
# android.googlesource.com/platform/bionic and re-fetchable from there when
# upstream moves. All build objects land in a scratch dir, never in this tree.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DEFAULT="$HOME/.local/opt/android-sdk/ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-arm64/bin"

if [ $# -gt 0 ]; then
  CCS=("$@")
else
  # one wrapper per ABI, lowest API level (the sysroot libc.a is per-ABI, not
  # per-API, and the wrapper only has to resolve the right lib dir).
  CCS=()
  for a in aarch64-linux-android armv7a-linux-androideabi i686-linux-android x86_64-linux-android riscv64-linux-android; do
    c="$(ls "$BIN_DEFAULT/${a}"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$c" ] && CCS+=("$c")
  done
  [ ${#CCS[@]} -gt 0 ] || { echo "no clang wrappers found in $BIN_DEFAULT" >&2; exit 1; }
fi

BIN="$(dirname "${CCS[0]}")"
[ -d "$HERE/src" ] || {
  echo "missing $HERE/src (fetch arc4random.c / arc4random.h / chacha_private.h first)" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arc4random-splice.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/inc/async_safe"
cat > "$WORK/inc/async_safe/log.h" <<'EOF'
#pragma once
int async_safe_fatal_no_abort(const char* fmt, ...)
    __attribute__((format(printf, 1, 2)));
#define async_safe_fatal(...) async_safe_fatal_no_abort(__VA_ARGS__)
EOF

for CC in "${CCS[@]}"; do
  # clang resolves the per-ABI lib dir itself (armv7a-linux-androideabi ->
  # arm-linux-androideabi), so ask it rather than reimplementing the mapping.
  LIBC="$("$CC" --print-file-name=libc.a)"
  [ -f "$LIBC" ] || { echo "$CC: no libc.a via --print-file-name ($LIBC)" >&2; exit 1; }
  echo "==> $CC -> $LIBC"

  "$CC" -O2 -fPIC -include "$HERE/compat.h" -I"$HERE" -I"$HERE/src" -I"$WORK/inc" \
      -c "$HERE/src/arc4random.c" -o "$WORK/arc4random.o"
  "$CC" -O2 -fPIC -c "$HERE/arc4_lock.c" -o "$WORK/arc4_lock.o"
  "$BIN/ld.lld" -r -o "$WORK/arc4random_merged.o" "$WORK/arc4random.o" "$WORK/arc4_lock.o"

  grep -aq MADV_WIPEONFORK "$WORK/arc4random_merged.o" \
    && { echo "refusing: replacement still carries MADV_WIPEONFORK" >&2; exit 1; }
  "$BIN/llvm-nm" --defined-only "$WORK/arc4random_merged.o" | grep -q ' T arc4random_mutex_lock' \
    || { echo "refusing: replacement lacks arc4random_mutex_lock" >&2; exit 1; }

  [ -f "$LIBC.orig-wipeonfork" ] || cp -p "$LIBC" "$LIBC.orig-wipeonfork"
  # Member replacement: llvm-ar matches the member by the basename it is given,
  # so stage the merged object under the name `arc4random.o` and archive from
  # the scratch dir (the kit tree itself stays clean).
  cp "$WORK/arc4random_merged.o" "$WORK/arc4random.o"
  ( cd "$WORK" && "$BIN/llvm-ar" r "$LIBC" arc4random.o )
  echo "    spliced arc4random.o into $LIBC"
done
