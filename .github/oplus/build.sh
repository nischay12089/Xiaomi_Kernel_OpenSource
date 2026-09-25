#!/bin/bash
# Build OnePlus (OPLUS) vendor modules for this device against a GKI kernel
# build and package them as a KernelSU module.
#
#   build.sh <kernel source> <kernel build dir (O=)> <output dir>
#
# KMAKE must run make with the same toolchain/flags as the kernel build
# (LLVM=1 ARCH=arm64 O=<kernel build dir> ...), e.g. the workflow's kmake.
# OPLUS_SRC can point to an existing checkout of the OnePlus modules repo.
set -euo pipefail

KSRC=$(realpath "$1")
KOUT=$(realpath "$2")
OUT=$(realpath -m "$3")
HERE=$(dirname "$(realpath "$0")")
DEVICE_ROOT=$(realpath "$HERE/../..")
: "${KMAKE:?KMAKE must be set}"

OPLUS_REPO=${OPLUS_REPO:-https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8735}
# oneplus/sm8735_b_16.0.0_turbo_6 (PLU110_16.0.5.702)
OPLUS_SHA=${OPLUS_SHA:-32e4ffa9249d3b682f4732eeffcf694d70648d0a}
# Provided by the device's vendor modules at runtime
ALLOWED_UNDEFINED="panel_event_notifier_register panel_event_notifier_unregister"

WORK="$OUT/work"
mkdir -p "$WORK" "$OUT"

if [ -z "${OPLUS_SRC:-}" ]; then
	OPLUS_SRC="$WORK/oplus_src"
	if [ ! -d "$OPLUS_SRC/.git" ]; then
		git init -q "$OPLUS_SRC"
		git -C "$OPLUS_SRC" remote add origin "$OPLUS_REPO"
		git -C "$OPLUS_SRC" sparse-checkout set --no-cone \
			/vendor/oplus/kernel/mm/hybridswap_zram/ \
			/vendor/oplus/kernel/mm/thp_zsmalloc/ \
			/vendor/oplus/kernel/mm/zstd_o/ \
			/vendor/oplus/kernel/cpu/
		git -C "$OPLUS_SRC" fetch -q --depth=1 --filter=blob:none origin "$OPLUS_SHA"
		git -C "$OPLUS_SRC" checkout -q FETCH_HEAD
	fi
fi
OK="$WORK/oplus_kernel"
rm -rf "${OK:?}"
cp -r "$OPLUS_SRC/vendor/oplus/kernel" "$OK"

for p in "$HERE"/patches/*.patch; do
	echo "Applying $(basename "$p")"
	patch -p1 -d "$OK" --forward < "$p"
done

B="$WORK/build"
rm -rf "${B:?}"
mkdir -p "$B"/mm/include/linux/soc/qcom "$B"/horae "$B"/sched/include/linux/sched

cp "$HERE"/mm/Kbuild "$HERE"/mm/oplus_fg_info.c "$B/mm/"
cp -r "$OK"/mm/hybridswap_zram "$OK"/mm/thp_zsmalloc "$OK"/mm/zstd_o "$B/mm/"
cp "$DEVICE_ROOT"/include/linux/soc/qcom/panel_event_notifier.h "$B/mm/include/linux/soc/qcom/"

cp "$HERE"/horae/Kbuild "$OK"/cpu/thermal/horae_shell_temp.[ch] "$B/horae/"

cp "$HERE"/sched/Kbuild "$B/sched/"
cp -r "$OK"/cpu/sched/sched_assist "$B/sched/"
cp "$DEVICE_ROOT"/include/linux/sched/walt.h "$B/sched/include/linux/sched/"
# sched_assist includes other OPLUS cpu headers as <../kernel/oplus_cpu/...>
ln -sfn "$OK/cpu" "$KSRC/kernel/oplus_cpu"

# External modules need scripts/module.lds and the vmlinux symbol versions
"$KMAKE" modules_prepare
[ -f "$KOUT/Module.symvers" ] || cp "$KOUT/vmlinux.symvers" "$KOUT/Module.symvers"

for m in mm horae sched; do
	echo "::group::Build OPLUS $m modules"
	"$KMAKE" M="$B/$m" KBUILD_MODPOST_WARN=1 modules 2>&1 | tee "$B/$m.log"
	echo "::endgroup::"
done
rm -f "$KSRC/kernel/oplus_cpu"

# Anything unresolved besides the vendor-provided symbols would fail to load
undefined=$(sed -n 's/^WARNING: modpost: "\([^"]*\)" \[.*\] undefined!$/\1/p' "$B"/*.log | sort -u)
for sym in $undefined; do
	case " $ALLOWED_UNDEFINED " in
	*" $sym "*) ;;
	*) echo "::error::Unresolved symbol in OPLUS modules: $sym"; exit 1 ;;
	esac
done

# sched_assist may only register the restricted hooks its preflight checks
checked=$(sed -n 's/^+\s*SA_CHECK_RVH(\(android_rvh_[a-z_0-9]*\));$/\1/p' "$HERE"/patches/*sched_assist*.patch | sort -u)
used=$(llvm-nm "$B/sched/oplus_bsp_sched_assist.ko" | sed -n 's/.* __tracepoint_\(android_rvh_[a-z_0-9]*\)$/\1/p' | sort -u)
missing=$(comm -13 <(echo "$checked") <(echo "$used"))
if [ -n "$missing" ]; then
	echo "::error::sched_assist registers restricted hooks not covered by its preflight: $missing"
	exit 1
fi

# KernelSU module
PKG="$WORK/ksu"
rm -rf "${PKG:?}"
mkdir -p "$PKG/modules" "$PKG/META-INF/com/google/android"
cp "$B"/mm/*.ko "$B"/horae/*.ko "$B"/sched/*.ko "$PKG/modules/"
llvm-strip --strip-debug "$PKG"/modules/*.ko
cp "$HERE"/ksu/post-fs-data.sh "$HERE"/ksu/service.sh "$PKG/"
cp "$HERE"/ksu/update-binary "$PKG/META-INF/com/google/android/update-binary"
echo "#MAGISK" > "$PKG/META-INF/com/google/android/updater-script"
cat "$KOUT/include/config/kernel.release" > "$PKG/kernel_release"
sed -e "s/@KERNEL_RELEASE@/$(cat "$PKG/kernel_release")/" \
	-e "s/@VERSION_CODE@/$(date +%Y%m%d)/" \
	-e "s/@AUTHOR@/${GITHUB_REPOSITORY_OWNER:-local}/" \
	"$HERE"/ksu/module.prop > "$PKG/module.prop"
rm -f "$OUT/oplus_modules.zip"
(cd "$PKG" && zip -qr9 "$OUT/oplus_modules.zip" .)

echo "Built OPLUS modules for $(cat "$PKG/kernel_release"):"
ls -l "$PKG/modules"
