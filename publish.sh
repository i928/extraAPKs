#!/bin/bash
#
# publish.sh -- promote the freshly generated extra-apps to all device trees.
#
# Workflow:
#   1. drop a new APK into ~/extraAPKs/
#   2. ./run.sh          -> regenerates ~/extraAPKs/extra-apps (scratch output)
#   3. ./publish.sh      -> promotes it to extra-apps-official and re-links the
#                           device trees to it
#
# Why a separate step: run.sh starts with `rm -rf extra-apps`, so its output dir
# must never be what the trees point at. extra-apps-official is the promoted
# snapshot -- it only changes when you deliberately run this, which is what keeps
# an in-flight build from seeing a half-regenerated app set.
#
# Why re-linking is required: the trees are HARDLINKED to extra-apps-official
# (chosen over a read-only bind mount: no sudo, no /etc/fstab entry, and it
# survives a reboot on its own). Hardlinks share inodes, so every same-filesystem
# copy costs one 2.2 GB on disk -- but rsync replaces files rather than writing
# through them, so after a promote the trees still reference the OLD inodes until
# this script re-links them. A bind mount would have propagated automatically;
# this is the one thing hardlinks ask for in exchange.
#
# Hardlinks cannot cross filesystems. ~/lin23 is a symlink to /build/lin23 (root
# LV on sda, a plain directory rather than its own mount; lin23 was moved there to
# spread disk use), while ~/extraAPKs is on /home (nvme0n1), so `cp -al` there fails with
# "Invalid cross-device link". Trees on another filesystem get a real copy via
# rsync instead: 2.2 GB more disk, and only changed files are rewritten.

set -e
cd "$(dirname "$0")"

SRC=extra-apps
OFF=extra-apps-official
TREES=(
    /home/android/evo-11.9/device/google/sunfish/prebuilts/extra-apps
    /home/android/evo-11.9/device/xiaomi/lmi/extra-apps
    /home/android/lin22/device/google/crosshatch/prebuilts/extra-apps
    /home/android/lin22/device/xiaomi/lmi/extra-apps
    /home/android/lin23/device/xiaomi/lmi/extra-apps
    /home/android/lin23/device/google/crosshatch/prebuilts/extra-apps
    /home/android/lin23/device/google/sunfish/prebuilts/extra-apps
)

# Trees whose kernel runs KernelSU-Next UAPI 2 (3.3 driver). The 3.4 manager
# (KernelSUNext.apk, UAPI 4) shows "Unsupported" there, so these trees get
# KernelSUNext-uapi2.apk (the 3.3 manager, same package dev.i928.mgr, same key,
# versionCode 33300 > 3.4's 33296) copied in under the same name. The module
# name must stay KernelSUNext: Soong installs to /product/app/<module>/, where
# each device's ksud_prebuilt (3.3) is placed. Move a tree to UAPI 4 by
# dropping it from this list once its kernel carries the 3.4 driver
# (crosshatch: dropped 2026-10-02, kernel ksu34-test + device ksu34;
# lin23 lmi: dropped 2026-10-02, kernel + device branch ksu34;
# evo lmi and lin22 lmi: dropped 2026-10-02. The list is empty now: every
# tree runs the 3.4 driver. Kept for a tree that ever needs UAPI 2 again.)
# Alternate managers live in managers/: run.sh turns every ./*.apk into an app
# module, and a second dev.i928.mgr apk there would ship as a duplicate package.
UAPI2_MANAGER=managers/KernelSUNext-uapi2.apk
UAPI2_TREES=(
)
is_uapi2() { local t; for t in "${UAPI2_TREES[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }

# Trees whose kernel runs KernelSU-Next UAPI 4 (3.4.0 driver). KernelSUNext.apk is
# the 3.4.1 manager (UAPI 5, 2026-10-10), which needs the uapi5 driver; these trees
# keep the 3.4.0 manager (KernelSUNext-uapi4.apk, versionCode 33296) until their
# kernel is bumped -- then drop the tree from this list. Their ksud_prebuilt must
# match too (3.4.0 ksud with a UAPI-4 kernel). sunfish moved to 3.4.1 first
# (kernel + device branch ksu-3.4.1).
UAPI4_MANAGER=managers/KernelSUNext-uapi4.apk
UAPI4_TREES=(
    /home/android/evo-11.9/device/xiaomi/lmi/extra-apps
    /home/android/lin22/device/xiaomi/lmi/extra-apps
)
is_uapi4() { local t; for t in "${UAPI4_TREES[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }

[ -d "$SRC" ] || { echo "!! $SRC missing -- run ./run.sh first"; exit 1; }
[ -s "$UAPI2_MANAGER" ] || { echo "!! $UAPI2_MANAGER missing (3.3 manager for UAPI-2 kernels)"; exit 1; }
[ -s "$UAPI4_MANAGER" ] || { echo "!! $UAPI4_MANAGER missing (3.4.0 manager for UAPI-4 kernels)"; exit 1; }

# Refuse to swap files under a running build: the trees are inputs to Soong, and
# replacing an APK mid-build yields a corrupt or half-stale image. soong_ui runs
# ninja by a RELATIVE path (prebuilts/build-tools/linux-x86/bin/ninja), so match the
# binary name after any "/" rather than requiring an absolute path.
BUILD_RE='(^|/)(soong_ui|soong_build|ninja|ckati)( |$)'
if pgrep -f "$BUILD_RE" >/dev/null 2>&1; then
    echo "!! a build appears to be running -- refusing to republish"
    pgrep -af "$BUILD_RE" | cut -c1-120 | head -3
    exit 1
fi

# A copy that is not in TREES never gets republished and silently goes stale.
for root in /home/android/evo-11.9 /home/android/lin22 /home/android/lin23; do
    find -L "$root/device" -mindepth 3 -maxdepth 4 -type d -name extra-apps 2>/dev/null
done | while read -r found; do
    listed=0
    for d in "${TREES[@]}"; do [ "$(realpath "$d" 2>/dev/null)" = "$(realpath "$found")" ] && listed=1; done
    [ $listed = 1 ] || echo "  WARN not in TREES, will go stale: $found"
done

same_fs() { [ "$(stat -L -c %d "$OFF")" = "$(stat -L -c %d "$(dirname "$1")")" ]; }

# Soong/ninja rebuild by mtime. A file swapped in with an OLDER mtime than the
# tree's previous one is taken as unchanged and the old version ships
# (2026-10-02: crosshatch moved from its own 3.3 manager copy back to the shared
# 3.4 one, whose mtime was older, and the OTA still carried 3.3). So every file
# whose content changes gets the current time:
#   - files that differ between run.sh's output and the promoted copy
#   - each tree's KernelSUNext.apk when its content changes (UAPI-2/UAPI-4 swap)
changed=$(rsync -ai --checksum --dry-run "$SRC/" "$OFF/" | awk '$1 ~ /^>f/ {print $2}')
declare -A PREV_MGR
for d in "${TREES[@]}"; do
    PREV_MGR[$d]=$(sha256sum "$d/prebuilt/KernelSUNext.apk" 2>/dev/null | cut -c1-64)
done

echo "==> promoting $SRC -> $OFF"
# --checksum --no-times: files with unchanged content are left alone (their
# mtime too); plain -a would reset an unchanged file's mtime to run.sh's
# older copy, which is how the fix below got undone the first time.
rsync -a --no-times --checksum --delete "$SRC/" "$OFF/"
for f in $changed; do touch "$OFF/$f"; echo "  changed, mtime now: $f"; done

echo "==> re-linking device trees"
linked=0
for d in "${TREES[@]}"; do
    [ -d "$(dirname "$d")" ] || { echo "  SKIP (no parent): $d"; continue; }
    if same_fs "$d"; then
        # Build the new link farm beside the old one and swap, so a failure
        # partway never leaves the tree without an extra-apps dir.
        rm -rf "$d.new"
        cp -al "$OFF" "$d.new"
        rm -rf "$d"
        mv "$d.new" "$d"
        linked=$((linked + 1))
        echo "  linked: $d"
    else
        rsync -a --delete "$OFF/" "$d/"
        echo "  copied (other filesystem): $d"
    fi
done

# UAPI-2 trees: own copy (not a hardlink) of the 3.3 manager under the shared name.
echo "==> UAPI-2 manager (3.3)"
for d in "${UAPI2_TREES[@]}"; do
    [ -f "$d/prebuilt/KernelSUNext.apk" ] || continue
    rm -f "$d/prebuilt/KernelSUNext.apk"
    cp -p "$UAPI2_MANAGER" "$d/prebuilt/KernelSUNext.apk"
    echo "  3.3 manager: $d"
done
echo "==> UAPI-4 manager (3.4.0)"
for d in "${UAPI4_TREES[@]}"; do
    [ -f "$d/prebuilt/KernelSUNext.apk" ] || continue
    rm -f "$d/prebuilt/KernelSUNext.apk"
    cp -p "$UAPI4_MANAGER" "$d/prebuilt/KernelSUNext.apk"
    echo "  3.4.0 manager: $d"
done
# A tree whose manager content changed (either direction) gets a fresh mtime.
for d in "${TREES[@]}"; do
    m="$d/prebuilt/KernelSUNext.apk"
    [ -f "$m" ] || continue
    if [ "$(sha256sum "$m" | cut -c1-64)" != "${PREV_MGR[$d]}" ]; then
        touch "$m"; echo "  manager changed, mtime now: $d"
    fi
done

# Boot scripts generated by run.sh (ksu_script.sh, precopy.sh) run from
# each tree's ksu-autoinstall/scripts/, which device.mk ships to /product (sunfish,
# crosshatch); trees without a ksu-autoinstall/scripts/ dir are skipped.
echo "==> ksu-autoinstall scripts"
for d in "${TREES[@]}"; do
    dst=$(dirname "$(dirname "$d")")/ksu-autoinstall/scripts
    [ "$(basename "$(dirname "$d")")" = prebuilts ] || dst=$(dirname "$d")/ksu-autoinstall/scripts
    [ -d "$dst" ] || continue
    for f in "$OFF"/scripts/*.sh; do
        [ -f "$f" ] || continue
        cp "$f" "$dst/"
        echo "  copied: $dst/${f##*/}"
    done
done

# Evo's (and LineageOS 23's) build/soong refuses Android.mk files under
# denylisted prefixes such as device/google/, which includes sunfish's
# extra-apps/sepolicy/Android.mk. Soong also reads an allowlist from
# vendor/extra/build/androidmk/allowlist.txt; vendor/extra is not a repo
# project, so an entry there survives repo sync, unlike an edit to build/soong.
echo "==> androidmk allowlist"
for d in "${TREES[@]}"; do
    [ -f "$d/sepolicy/Android.mk" ] || continue
    root=$(realpath "$d"); root=${root%%/device/*}
    grep -qF 'vendor/extra/build/androidmk/allowlist.txt' "$root/build/soong/ui/build/androidmk_denylist.go" 2>/dev/null || continue
    rel=$(realpath "$d/sepolicy/Android.mk"); rel=${rel#"$root"/}
    list="$root/vendor/extra/build/androidmk/allowlist.txt"
    mkdir -p "$(dirname "$list")"
    if grep -qxF "$rel" "$list" 2>/dev/null; then
        echo "  present: $rel"
    else
        echo "$rel" >> "$list"; echo "  added:   $rel -> $list"
    fi
done

echo "==> verify"
fail=0
for d in "${TREES[@]}"; do
    [ -d "$d" ] || continue
    if is_uapi2 "$d"; then
        if diff -rq --exclude=KernelSUNext.apk "$d" "$OFF" >/dev/null 2>&1 &&
           cmp -s "$d/prebuilt/KernelSUNext.apk" "$UAPI2_MANAGER"; then
            echo "  IDENTICAL  $d  (+3.3 manager)"
        else
            echo "  !! DIFFERS  $d"; fail=1
        fi
    elif is_uapi4 "$d"; then
        if diff -rq --exclude=KernelSUNext.apk "$d" "$OFF" >/dev/null 2>&1 &&
           cmp -s "$d/prebuilt/KernelSUNext.apk" "$UAPI4_MANAGER"; then
            echo "  IDENTICAL  $d  (+3.4.0 manager)"
        else
            echo "  !! DIFFERS  $d"; fail=1
        fi
    elif diff -rq "$d" "$OFF" >/dev/null 2>&1; then
        echo "  IDENTICAL  $d"
    else
        echo "  !! DIFFERS  $d"; fail=1
    fi
done
# Every APK should carry one link per hardlinked copy: official + the same-fs trees.
want=$(( 1 + linked ))
# KernelSUNext.apk is excluded: the UAPI-2/UAPI-4 trees hold their own copy of it.
bad=$(ls "$OFF"/prebuilt/*.apk | grep -v '/KernelSUNext\.apk$' | xargs stat -c %h | grep -vc "^${want}$" || true)
echo "  APKs not at link count $want: $bad"
[ "$bad" = 0 ] || fail=1

df -h /home /build 2>/dev/null | tail -n +2 | awk '{print "  "$6": "$4" free"}'
exit $fail
