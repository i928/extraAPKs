#!/system/bin/sh
#
# Hide the ROM's preinstalled YouTube apps so the ReVanced builds take over:
# bind an empty dir over each one, then register the mount with susfs so root
# detection does not see it.
#
# Run on every boot by ksu-autoinstall.sh (detached). KernelSU's own
# /data/adb/service.d is NOT run by this ksud, which is why this lives in the
# ROM at /product/etc/ksu-autoinstall/scripts/ instead.

# Wait for the system framework to stabilize completely
(
SUSFS=/data/adb/ksu/bin/ksu_susfs
# Marker for "this ran": /data/media/0, never /sdcard -- /sdcard resolves through
# /storage/self, which is per-mount-namespace and empty for a root process
# started outside a user's namespace, so writes there vanish silently.
LOG=/data/media/0/Download/boot_log.txt

# $1 = directory to hide, $2 = backing dir under /dev. Skipped quietly when the
# target is absent: which apps ship varies between builds (this ROM has
# YoutubeMusic but no YouTube), and a missing one is not an error.
hide_path() {
	[ -d "$1" ] || return 0
	mkdir -p "$2" || return 0
	mount -o bind "$2" "$1" || return 0
	[ -x "$SUSFS" ] && "$SUSFS" add_sus_path "$1"
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done

hide_path /product/app/YoutubeMusic /dev/empty_music
hide_path /product/app/YouTube /dev/empty_yt

# Hail (app freezer), when installed.
if [ -x "$SUSFS" ] && [ -d /data/data/com.aistra.hail ]; then
	"$SUSFS" add_sus_path /data/data/com.aistra.hail
fi

# Force the adb daemon property to root mode
#setprop service.adb.root 1
#setprop ro.secure=0
#setprop ro.debuggable=1
#setprop ro.adb.secure=0
#setprop persist.sys.usb.config=adb
#setprop ro.ap_debuggable=1

# Not a ksud 3.3.0 command ("unrecognized subcommand 'su'"). adb shell root on
# a wiped device comes from shell-root.allowlist, which ksu-autoinstall.sh seeds
# into /data/adb/ksu/.allowlist.
#ksud su -p com.android.shell

[ -d "${LOG%/*}" ] && echo "$(date) ksu_script.sh done" > "$LOG"
)&
