#!/system/bin/sh
# Marks the boot as good and appends the state of the OPLUS modules to boot.log.

CONF=/data/adb/oplus_compat

until [ "$(getprop sys.boot_completed)" = "1" ]; do
	sleep 2
done
rm -f "$CONF/.booting"

{
	echo "[$(date '+%H:%M:%S')] boot completed"
	echo "--- modules"
	grep -E "^(horae_shell_temp|oplus_)" /proc/modules
	echo "--- swaps"
	cat /proc/swaps
	echo "--- zram0: $(ls /sys/block/zram0 2>/dev/null | tr '\n' ' ')"
	echo "--- /proc/shell-temp: $(cat /proc/shell-temp 2>/dev/null)"
	for zone in /sys/class/thermal/thermal_zone*; do
		case "$(cat "$zone/type")" in
		shell_*) echo "$zone $(cat "$zone/type") $(cat "$zone/temp" 2>/dev/null)" ;;
		esac
	done
	echo "--- /proc/oplus_scheduler/sched_assist: $(ls /proc/oplus_scheduler/sched_assist 2>/dev/null | tr '\n' ' ')"
	echo "--- /proc/fg_info/fg_uids: $(cat /proc/fg_info/fg_uids 2>/dev/null)"
	echo "--- dmesg"
	dmesg | grep -iE "hybridswap|horae|shell.temp|sched_assist|oplus|zram|zsmalloc" | tail -n 100
} >> "$CONF/boot.log" 2>&1
