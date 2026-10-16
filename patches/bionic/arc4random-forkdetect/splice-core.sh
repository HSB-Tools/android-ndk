#!/usr/bin/env bash
# Shared per-ABI arc4random.o splice core.
#
# Sourced by scripts/make-ndk.sh (splice_arc4random) and by
# rebuild-arc4random.sh so the build, the two refusal gates, and the archive
# member replacement exist in exactly one place and cannot drift.
#
# It lives inside the kit directory on purpose: rebuild-arc4random.sh must stay
# standalone (it may run with only this tree present), so the shared file has to
# travel with the kit rather than with the build scripts.
#
# Callers own NDK discovery, ABI selection, the "nothing patched" check, and the
# splice-before-assemble ordering. This file owns only one ABI's splice.

# arc4_splice_work_init <work> <kit>
# Seed the scratch dir with the kit sources plus the async_safe stub header the
# vendored arc4random.c expects. Idempotent enough to call once per run.
arc4_splice_work_init() {
  local work="$1" kit="$2"
  mkdir -p "$work/inc/async_safe"
  cp -R "$kit/." "$work/"
  cat > "$work/inc/async_safe/log.h" <<'EOF'
#pragma once
int async_safe_fatal_no_abort(const char* fmt, ...)
    __attribute__((format(printf, 1, 2)));
#define async_safe_fatal(...) async_safe_fatal_no_abort(__VA_ARGS__)
EOF
}

# arc4_splice_abi <cc> <libc> <work>
# Build the replacement member from <work> and swap it into <libc>.
#   <cc>   the ABI's clang wrapper (its dirname is the toolchain bin dir)
#   <libc> that ABI's sysroot libc.a
#   <work> scratch dir already seeded by arc4_splice_work_init
# Returns non-zero (with a message) if a gate fails; the caller decides whether
# that aborts the whole run.
arc4_splice_abi() {
  local cc="$1" libc="$2" work="$3" bin
  bin="$(cd "$(dirname "$cc")" && pwd)"
  [ -f "$libc" ] || { echo "arc4_splice_abi: no libc.a at $libc" >&2; return 1; }

  "$cc" -O2 -fPIC -include "$work/compat.h" -I"$work" -I"$work/src" -I"$work/inc" \
      -c "$work/src/arc4random.c" -o "$work/arc4random.o"
  "$cc" -O2 -fPIC -c "$work/arc4_lock.c" -o "$work/arc4_lock.o"
  "$bin/ld.lld" -r -o "$work/arc4random_merged.o" \
      "$work/arc4random.o" "$work/arc4_lock.o"

  grep -aq MADV_WIPEONFORK "$work/arc4random_merged.o" \
    && { echo "arc4_splice_abi: replacement still carries MADV_WIPEONFORK" >&2; return 1; }
  "$bin/llvm-nm" --defined-only "$work/arc4random_merged.o" \
      | grep -q ' T arc4random_mutex_lock' \
    || { echo "arc4_splice_abi: replacement lacks arc4random_mutex_lock" >&2; return 1; }

  [ -f "$libc.orig-wipeonfork" ] || cp -p "$libc" "$libc.orig-wipeonfork"
  # llvm-ar matches the member by basename, so the merged object must be named
  # arc4random.o in the directory the archiver runs from.
  cp "$work/arc4random_merged.o" "$work/arc4random.o"
  ( cd "$work" && "$bin/llvm-ar" r "$libc" arc4random.o )
}
