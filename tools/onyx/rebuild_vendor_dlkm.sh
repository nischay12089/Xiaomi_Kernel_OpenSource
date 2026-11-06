#!/usr/bin/env bash
# Usage: rebuild_vendor_dlkm.sh STOCK_IMAGE FILE_CONTEXTS MANIFEST OUTPUT_IMAGE
# Manifest: one .ko path per line, relative to the manifest directory or absolute.
# Empty lines are ignored; an empty manifest produces a stock-content roundtrip.
set -euo pipefail
export LC_ALL=C
umask 022

die() { echo "error: $*" >&2; exit 1; }
[[ $# == 4 ]] || die "usage: $0 STOCK_IMAGE FILE_CONTEXTS MANIFEST OUTPUT_IMAGE"
for tool in realpath stat mktemp fsck.erofs mkfs.erofs depmod modinfo awk install; do
    command -v "$tool" >/dev/null || die "missing command: $tool"
done
stock=$(realpath -e -- "$1")
contexts=$(realpath -e -- "$2")
manifest=$(realpath -e -- "$3")
output=$(realpath -m -- "$4")
for input in "$stock" "$contexts" "$manifest"; do
    [[ -f $input && -r $input ]] || die "not a readable regular file: $input"
done
[[ ! -e $output && ! -L $output ]] || die "output already exists: $output"
[[ -d $(dirname -- "$output") ]] || die "output directory does not exist"
# /var/tmp is deliberate: TMPDIR may point to a Windows mount with synthetic permissions.
work=$(mktemp -d /var/tmp/onyx-vendor-dlkm.XXXXXXXX)
echo "Staging and retained diagnostics: $work" >&2
trap 'rc=$?; if (( rc != 0 )); then echo "Failed; diagnostics retained at $work" >&2; fi' EXIT
case $(stat -f -c %T "$work") in
    ext2/ext3|ext4|tmpfs|btrfs|xfs) ;;
    *) die "staging must use a native Linux filesystem" ;;
esac
fsck.erofs --extract="$work/tree" --preserve-perms --xattrs "$stock" >"$work/extract.log" 2>&1
mods=$work/tree/lib/modules
[[ -d $mods && ! -L $mods ]] || die "stock has no regular lib/modules directory"
for metadata in modules.load modules.dep modules.alias modules.softdep modules.blocklist; do
    [[ -f $mods/$metadata && ! -L $mods/$metadata ]] || die "missing regular stock metadata: $metadata"
done
# --all-root is valid only for a stock image whose entries are already root-owned.
# The caller must use a root-owned Android vendor_dlkm stock image.
declare -A seen=()
for module in "$mods"/*.ko; do
    [[ -f $module && ! -L $module ]] || die "invalid stock module: $module"
    name=${module##*/}; key=${name%.ko}; key=${key//-/_}
    [[ ! ${seen[$key]+yes} ]] || die "duplicate stock module name: $name"
    seen[$key]=1
done
sources=(); names=(); release=
while IFS= read -r source || [[ -n $source ]]; do
    [[ -n $source ]] || continue
    [[ $source != *$'\r'* ]] || die "manifest must use Unix line endings"
    [[ $source == /* ]] || source=$(dirname -- "$manifest")/$source
    source=$(realpath -e -- "$source")
    name=${source##*/}
    [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*\.ko$ && -f $source && -r $source ]] || die "invalid module path: $source"
    key=${name%.ko}; key=${key//-/_}
    [[ ! ${seen[$key]+yes} && ! -e $mods/$name && ! -L $mods/$name ]] || die "stock overwrite or duplicate addition: $name"
    # Also reject names already mentioned by stock's load list.
    if awk -v n="$name" '{sub(/^.*\//, ""); if ($0 == n) found=1} END {exit !found}' "$mods/modules.load"; then
        die "module already in stock modules.load: $name"
    fi
    magic=$(modinfo -F vermagic "$source")
    current=${magic%% *}
    [[ $current =~ ^[A-Za-z0-9_.+-]+$ ]] || die "invalid module release: $source"
    [[ -z $release || $release == "$current" ]] || die "mixed addition kernel releases"
    release=$current
    seen[$key]=1; sources+=("$source"); names+=("$name")
done <"$manifest"
if (( ${#names[@]} )); then
    dm=$work/depmod/lib/modules/$release
    mkdir -p "$dm"
    cp -- "$mods"/*.ko "$dm/"
    for i in "${!names[@]}"; do
        install -m 0644 -- "${sources[$i]}" "$mods/${names[$i]}"
        cp -- "$mods/${names[$i]}" "$dm/"
    done
    # shortcut: depmod -w does not reject unresolved imports, CRC mismatches or cycles;
    # validate against matching kernel symbols separately before deployment.
    if ! depmod -w -b "$work/depmod" "$release" >"$work/depmod.stdout" 2>"$work/depmod.stderr"; then
        cat "$work/depmod.stderr" >&2; die "depmod failed"
    fi
    # Missing optional kernel metadata warnings remain visible; never discard diagnostics.
    cat "$work/depmod.stderr" >&2
    for name in "${names[@]}"; do
        awk -v n="$name:" '
            $1 == n {
                count++; printf "/vendor/lib/modules/%s", $1
                for (i=2; i<=NF; i++) {
                    if ($i ~ /\//) exit 2
                    printf " /vendor/lib/modules/%s", $i
                }
                printf "\n"
            }
            END {if (count != 1) exit 1}
        ' "$dm/modules.dep" >>"$mods/modules.dep"
        printf '%s\n' "$name" >>"$mods/modules.load"
        key=${name%.ko}; key=${key//-/_}
        modinfo -F alias "$mods/$name" >"$work/aliases"
        while IFS= read -r alias; do
            [[ -z $alias ]] || printf 'alias %s %s\n' "$alias" "$key" >>"$mods/modules.alias"
        done <"$work/aliases"
        modinfo -F softdep "$mods/$name" >"$work/softdeps"
        while IFS= read -r softdep; do
            [[ -z $softdep ]] || printf 'softdep %s %s\n' "$key" "$softdep" >>"$mods/modules.softdep"
        done <"$work/softdeps"
    done
fi
# Reject any missing dependency target, including a malformed generated record.
awk '{for (i=1; i<=NF; i++) {sub(/:$/, "", $i); sub(/^.*\//, "", $i); print $i}}' "$mods/modules.dep" >"$work/dep-paths"
while IFS= read -r name; do
    [[ -f $mods/$name ]] || die "dependency target is missing: $name"
done <"$work/dep-paths"
mkfs.erofs -zlz4hc --all-root --preserve-mtime --mount-point=/vendor \
    --file-contexts="$contexts" "$work/candidate.img" "$work/tree" >"$work/mkfs.log" 2>&1
fsck.erofs --extract "$work/candidate.img" >"$work/verify.log" 2>&1
# noclobber also protects against an output created after the initial check.
(set -o noclobber; cat "$work/candidate.img" >"$output")
echo "Candidate only: $output"
