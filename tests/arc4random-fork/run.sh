#!/usr/bin/env bash
# Build the fork oracle against the NDK's sysroot libc.a for each ABI that can
# execute on this host, and assert the fork-safety property.
#
#   ./run.sh [ndk-prebuilt-bin-dir]
#
# Default bin dir: the newest NDK under ~/.local/opt/android-sdk/ndk, or
# $ANDROID_NDK_HOME. Only ABIs the host can actually run are exercised:
# aarch64 natively, arm via kernel COMPAT. i686/x86_64/riscv64 are skipped with
# a notice (no qemu on this device).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

BIN="${1:-}"
if [ -z "$BIN" ]; then
  for d in "${ANDROID_NDK_HOME:-}"/toolchains/llvm/prebuilt/*/bin \
           "$HOME"/.local/opt/android-sdk/ndk/*/toolchains/llvm/prebuilt/*/bin; do
    [ -d "$d" ] && BIN="$d" && break
  done
fi
[ -n "$BIN" ] && [ -d "$BIN" ] || { echo "no NDK bin dir; pass one as arg 1" >&2; exit 1; }
echo "toolchain: $BIN"

OUT="${TMPDIR:-$HOME/.qwen/tmp}/arc4-fork-oracle"
mkdir -p "$OUT"
rc=0
for abi in aarch64-linux-android armv7a-linux-androideabi; do
  cc="$(ls "$BIN/$abi"*-clang 2>/dev/null | head -n1)"
  [ -n "$cc" ] || { echo "SKIP $abi (no wrapper)"; continue; }
  bin="$OUT/$abi-oracle"
  "$cc" -O2 -static "$HERE/fork_oracle.c" -o "$bin"
  echo "=== $abi ==="
  if "$bin"; then :; else rc=1; fi
done
for abi in i686-linux-android x86_64-linux-android riscv64-linux-android; do
  echo "SKIP $abi (no qemu/binfmt on this host)"
done
exit "$rc"
