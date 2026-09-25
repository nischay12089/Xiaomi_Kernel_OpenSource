# OnePlus modules for POCO F7 (OPLUS ROM ports)

`build.sh` builds OnePlus vendor modules from
[android_kernel_modules_and_devicetree_oneplus_sm8735](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8735)
(OnePlus Turbo 6, pinned in `build.sh`) against the GKI kernel of the
workflow and packs them as a KernelSU module. Enable it with the
`oplus_modules` workflow input: the AnyKernel3 zip then installs
`oplus_modules.zip` through KernelSU, which is also uploaded on its own.

| Module | Provides |
| --- | --- |
| `oplus_bsp_hybridswap_zram` (+ `oplus_bsp_zsmalloc`, `oplus_bsp_zstdn`, `oplus_bsp_zstdn_o`) | zram0 with the hybridswap attributes and memcg files, replacing the stock zram at boot |
| `horae_shell_temp` | `/proc/shell-temp` and the `shell_front`/`shell_frame`/`shell_back` thermal zones |
| `oplus_bsp_sched_assist` | `/proc/oplus_scheduler/sched_assist/*` (opt-in) |
| `oplus_fg_info` | `/proc/fg_info/fg_uids` and `is_fg()`, normally from OnePlus sched_info |

`patches/` adapts the OnePlus sources to the Xiaomi vendor side: panel lookup
and notifier slot, zsmalloc symbol clash, memcg/pgdat oem data left by the
Xiaomi zram, shell zones without device tree nodes, and a sched_assist
preflight for the restricted vendor hook slots and task/rq oem data.

sched_assist only brings its proc interface and its own vendor hooks: on
OnePlus phones most of it runs inside the OnePlus WALT, which the Xiaomi
vendor modules don't have.

## On the phone

Files in `/data/adb/oplus_compat` (kept across module updates), applied on the
next boot:

- `enable_sched_assist`: load sched_assist
- `disable_hybridswap`: keep the stock zram
- `disable_horae`: don't load horae_shell_temp

`boot.log` records what was loaded and the resulting state. If a boot doesn't
complete, the next one disables hybridswap and sched_assist on its own.
