#!/bin/bash
# Build the onyx (POCO F7, SM8735) kernel Image from this tree, KMI/ABI enforcement off.
# Config = what Xiaomi's "perf" (user) variant uses: gki_defconfig + sun_perf + onyx_perf.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/onyx-toolchain/clang-r510928/bin:$PATH"
OUT=out
V=arch/arm64/configs/vendor
# HOSTCFLAGS: host glibc >= 2.43 makes strchr() return const char *, which -Werror in tools/lib/bpf rejects
M=(make -j"$(nproc)" O=$OUT ARCH=arm64 LLVM=1 LLVM_IAS=1 KCFLAGS=-D__ANDROID_COMMON_KERNEL__
   HOSTCFLAGS=-Wno-incompatible-pointer-types-discards-qualifiers)

"${M[@]}" gki_defconfig
scripts/kconfig/merge_config.sh -m -O $OUT $OUT/.config $V/sun_perf.config $V/onyx_perf.config
# KMI/ABI off: no export trimming, no GKI protected-symbol checks (our signing key != stock,
# so stock system_dlkm/vendor modules count as unsigned and would get -EACCES).
scripts/config --file $OUT/.config -d TRIM_UNUSED_KSYMS -d MODULE_SIG_PROTECT -d MODULE_SIG_FORCE \
  -d XM_POWER_SUPPLY  # mca/ charging source not in Xiaomi's OSS drop; the .ko already lives on vendor_dlkm
"${M[@]}" olddefconfig
"${M[@]}" Image "$@"
