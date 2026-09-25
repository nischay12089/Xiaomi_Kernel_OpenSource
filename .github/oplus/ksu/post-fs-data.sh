#!/system/bin/sh
# Loads the OPLUS modules built with this kernel.
#
# Toggles: create/remove these files in /data/adb/oplus_compat (kept across
# module updates), then reboot
#   disable_horae        don't load horae_shell_temp (/proc/shell-temp, shell_* thermal zones)
#   disable_hybridswap   keep the stock zram instead of OPLUS hybridswap zram
#   enable_sched_assist  load OPLUS sched_assist (/proc/oplus_scheduler/sched_assist)
# Log: /data/adb/oplus_compat/boot.log (previous boot: boot.log.old)

MODDIR=${0%/*}
KO=$MODDIR/modules
CONF=/data/adb/oplus_compat
LOG=$CONF/boot.log
ZRAM=/sys/block/zram0

mkdir -p "$CONF"
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
exec >"$LOG" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
loaded() { grep -q "^$1 " /proc/modules; }
load() {
	if loaded "$1"; then
		log "$1: already loaded"
		return 0
	fi
	if insmod "$KO/$1.ko"; then
		log "$1: loaded"
		return 0
	fi
	log "$1: FAILED"
	dmesg | tail -n 5
	return 1
}

log "kernel $(uname -r), modules built for $(cat "$MODDIR/kernel_release")"
if [ "$(uname -r)" != "$(cat "$MODDIR/kernel_release")" ]; then
	log "modules don't match the running kernel, not loading anything"
	exit 0
fi

# Previous boot never reached boot_completed: stay away from the risky parts
if [ -f "$CONF/.booting" ]; then
	log "previous boot did not complete: disabling hybridswap and sched_assist"
	touch "$CONF/disable_hybridswap"
	rm -f "$CONF/enable_sched_assist"
fi
touch "$CONF/.booting"

[ -f "$CONF/disable_horae" ] || load horae_shell_temp
load oplus_fg_info
[ -f "$CONF/enable_sched_assist" ] && load oplus_bsp_sched_assist

restore_stock_zram() {
	loaded zram && return 0
	for dir in /vendor_dlkm/lib/modules /vendor/lib/modules /system_dlkm/lib/modules; do
		ko=$(find "$dir" -name zram.ko 2>/dev/null | head -n 1)
		[ -n "$ko" ] && insmod "$ko" && log "stock zram restored from $ko" && return 0
	done
	log "could not reload the stock zram module"
	return 1
}

setup_zram() {
	[ "$size" -gt 0 ] 2>/dev/null || return 0
	i=0
	while [ ! -b /dev/block/zram0 ] && [ $i -lt 10 ]; do
		sleep 0.5
		i=$((i + 1))
	done
	if [ -n "$algo" ] && ! echo "$algo" > $ZRAM/comp_algorithm; then
		log "compression $algo not available, using $(cat $ZRAM/comp_algorithm)"
	fi
	echo "$size" > $ZRAM/disksize
	if [ -n "$prio" ]; then
		mkswap /dev/block/zram0 >/dev/null && swapon -p "$prio" /dev/block/zram0 &&
			log "zram0 swap on again: $size bytes, priority $prio"
	fi
}

swap_in_hybridswap() {
	if [ -e $ZRAM/hybridswap_enable ]; then
		log "hybridswap zram already active"
		return 0
	fi

	size=0 algo="" prio=""
	if [ -e $ZRAM/disksize ]; then
		size=$(cat $ZRAM/disksize)
		algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' $ZRAM/comp_algorithm)
		prio=$(awk '$1 == "/dev/block/zram0" { print $5 }' /proc/swaps)
	fi
	log "stock zram0: disksize=$size algorithm=${algo:-none} swap priority=${prio:-off}"

	if [ -n "$prio" ] && ! swapoff /dev/block/zram0; then
		log "swapoff failed, keeping stock zram"
		return 1
	fi
	[ -e $ZRAM/reset ] && echo 1 > $ZRAM/reset
	if loaded zram && ! rmmod zram; then
		log "stock zram can't be unloaded, keeping it"
		setup_zram
		return 1
	fi

	if load oplus_bsp_zsmalloc && load oplus_bsp_zstdn && load oplus_bsp_zstdn_o &&
		load oplus_bsp_hybridswap_zram; then
		setup_zram
		log "hybridswap zram0 attributes: $(for attr in "$ZRAM"/hybridswap_*; do printf '%s ' "${attr##*/}"; done)"
	else
		log "hybridswap zram unavailable, going back to the stock zram"
		restore_stock_zram && setup_zram
	fi
}

if [ -f "$CONF/disable_hybridswap" ]; then
	log "hybridswap disabled"
else
	swap_in_hybridswap
fi
