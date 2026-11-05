#!/bin/bash
# Build the onyx (POCO F7, SM8735) kernel Image from this tree.
# Config = onyx_defconfig: the stock 6.6.118 GKI kernel's own config (the phone's /proc/config.gz),
# adapted to this tree with KMI/ABI enforcement off: no export trimming, no GKI protected-symbol
# checks (our signing key != stock, so stock modules count as unsigned and would get -EACCES).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/onyx-toolchain/clang-r510928/bin:$PATH"
# HOSTCFLAGS: host glibc >= 2.43 makes strchr() return const char *, which -Werror in tools/lib/bpf rejects
M=(make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 KCFLAGS=-D__ANDROID_COMMON_KERNEL__
   HOSTCFLAGS=-Wno-incompatible-pointer-types-discards-qualifiers)

"${M[@]}" onyx_defconfig
"${M[@]}" Image "$@"
