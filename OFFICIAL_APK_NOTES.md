# Why MtManager and iFlyIME "failed" with the official APKs

## General lesson: neither source is a guarantee

Two different provenances got mixed up in this batch:
- `~/offical` = downloaded fresh from each app's official website/distributor.
- `/home/android/app2/sogou/sogou.apk` (and similarly-sourced earlier apps)
  = pulled from the user's own personal device backup/restore.

Intuition says "downloaded from the official site" should be the safer,
cleaner bet -- but that wasn't true here. **Neither source is a guarantee**;
every apk still needs the same verification pass (compressed `lib/*.so`,
`resources.arsc` alignment, and now confirmed: whether the app's actual code
is even shipped as normal `classes*.dex` files, vs. hidden behind a
dex-hardening/protection scheme in an obfuscated assets file).

Confirmed case (2026-08-27): the official-site-downloaded `sogou-input.apk`
in `~/offical` turned out to be **dex-hardened** -- no real `classes.dex` at
the apk root, its actual code lives in an obfuscated `assets/A3AEECD8.dex`
instead (many official distributor sites wrap their downloads in an
anti-piracy protection SDK before publishing). That can't survive being
repackaged into a system-partition APK at all (`ClassNotFoundException` /
`Failed to open dex files ... Entry not found` on the Application class,
crash on every launch). The user's own **backed-up** copy
(`/home/android/app2/sogou/sogou.apk`, versionName 20.9.0, normal multidex
`classes.dex`..`classes7.dex`, extracted from a real running install so no
distributor-side protection wrapper) had no such issue and worked fine
through the exact same pipeline -- reverted to that.

So: treat every apk regardless of which source it came from as needing the
full verification pass. Some official-site downloads were genuinely clean
(MtManager itself, revanced-manager-plus); some needed the standard resign
treatment (iFlyIME, FreeNovel, microG); and at least one (sogou-input.apk)
was fundamentally broken for this use case regardless of any resign/
decompress trick -- while the user's own backed-up copy of the same app was
fine.

## `default_dev_cert`'s resources.arsc alignment bug is not a one-off

By the end of this round it had hit **four separate binaries across three
apps**: the original FreeNovel, the official-site FreeNovel replacement, the
original sogou, and even the user's own backed-up sogou.apk (after it
replaced the broken official one). Every time: `run.sh`'s
`has_preprocessed_issues()` correctly flags compressed `lib/*.so` and routes
the apk through Soong's `default_dev_cert` re-sign path, and Soong
decompresses the JNI libs fine but leaves `resources.arsc` **misaligned** in
the built output (confirmed via `zipalign -c -v 4` on the actual installed
partition copy showing `resources.arsc (BAD)`), even when it started out
correctly stored+aligned in the source apk. It doesn't happen to every apk
on that path (adaway, Youtube, both worked fine unmodified) -- looks
byte-layout-dependent, not something to predict up front.

**There is also a nasty second-order symptom**: PackageManagerService can
mask this failure entirely. After a first bad build, PMS's parse cache kept
serving the *previous good* version's metadata (`dumpsys package` showing a
stale `versionCode`/`lastUpdateTime` from days earlier) instead of visibly
failing, even though the actual file on `/product` had changed and the new
content couldn't parse. `adb logcat` still shows the real
`Failed to parse ... resources.arsc ... uncompressed and aligned` line at
boot, so that's the authoritative signal -- but a `pm list packages` /
`dumpsys package` check alone can lie and make a broken build look installed
and up to date. Forcing a real re-scan (root + `rm -rf
/data/system/package_cache/*` + reboot) is what surfaced the sogou case
here; it then wiped the package's registration entirely ("System package
... no longer exists; its data will be wiped") once the stale cache
covering it was gone.

**How to apply going forward:** for any app `run.sh` reports as having
"misaligned/compressed native libs" (i.e. taking the `default_dev_cert`
path), proactively run `prepare_apk_general.sh` on it first and let it take
the `presigned+preprocessed` path instead of trusting `default_dev_cert` --
cheaper than a full rebuild+reflash+reboot cycle to discover the alignment
bug after the fact. And when verifying a swap, don't just check
`pm list packages` -- check `dumpsys package <name>` for a versionCode/
versionName match against what was actually built, since a stale-but-present
entry can hide a silent parse failure.

## sogou (com.sohu.inputmethod.sogou) -- KNOWN ISSUE, not pursuing further for now

After fixing the resources.arsc alignment bug above (`prepare_apk_general.sh`
applied to the user's backed-up `/home/android/app2/sogou/sogou.apk`,
v2540/20.9.0), the app now installs and registers correctly (confirmed via
`dumpsys package` showing the right versionCode/lastUpdateTime, no parse
errors in logcat) and launches. But it then hits a **native crash**, a
different class of bug than everything above:

```
F libc: Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0
        in tid <input_engine_wo>, pid <sogou>
```

NULL-pointer dereference inside its native input-engine worker thread, not a
packaging/signing/alignment issue -- happens after the app is already
correctly installed and its Application class instantiates fine. Possible
causes (unconfirmed, not investigated further per user direction
2026-08-27): the native engine needs an asset/config path that doesn't
resolve correctly once repackaged into a system-partition apk, or a genuine
incompatibility between this app version and this Android 12 base
regardless of packaging.

**Status: left as a known issue.** sogou is installed and will show up in
the keyboard picker, but expect it to crash if actually selected/used as an
input method. Not blocking anything else; revisit only if this specific app
becomes a priority again.

## MtManager (bin.mt.plus) — cannot be baked into the ROM, period

The official `mt-manager.apk` (from `~/offical/mt-manager.apk`) verifies its
own signature fine and its `resources.arsc` is stored/aligned correctly.
The problem is `lib/arm64-v8a/*.so` — specifically `libmtprotect.so` and
`libhook.so`, MT Manager's own anti-tamper/anti-piracy native code — which
are shipped **compressed** inside the APK.

This creates two requirements that are mutually exclusive for a system app:

1. **To pass MtManager's own anti-tamper check**: the APK's bytes must be
   100% unmodified — its v2/v3 signature is a hash over the entire file, so
   even just decompressing one `.so` entry invalidates it and trips the
   "no implementation found" JNI registration failure we saw crash-looping
   earlier (confirmed via `dumpsys dropbox --print system_app_crash`).
2. **To have working native libraries at all**: compressed `lib/*.so`
   entries need to be decompressed and 4-byte aligned so the OS can `mmap`
   them directly out of the APK (required since `/product` is **EROFS** —
   confirmed via `mount -o rw,remount /product` → `Read-only file system`,
   so there is no runtime extraction path the way there is for apps
   installed to `/data`). Decompressing means modifying the file, which
   breaks requirement 1.

Soong's `android_app_import` has no way to satisfy both at once for a
partition-baked system app. A normal `pm install` to `/data` (via `adb
install` after boot) sidesteps this entirely: the standard install path
decompresses/extracts native libs into `/data/app/.../lib/` automatically
regardless of how they're packed, **without** touching the APK's signature.
That's why sideloading the official APK post-boot is the only combination
that gets a working, non-crashing MtManager. Confirmed net-new signature
conflict via a live device test: `adb install -r -d` refused with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE: ... signatures do not match`, since the
previously-baked (default_dev_cert-resigned) system copy has a different
signature than the official one, and `/product` can't be edited to remove it.

**Decision (2026-08-27): dropped from the ROM build entirely.** No more
`extraAPKs/MtManager.apk`. Install the official one yourself post-boot:
`adb install ~/offical/mt-manager.apk`.

## iFlyIME (com.iflytek.inputmethod) — not actually broken, just needs the
normal resign treatment

`zipalign -c` flags 3 stray `lib/armeabi/*.so` entries as misaligned, and
`apksigner verify` on the untouched file is otherwise clean. But that's a
red herring: this device is arm64-v8a, so the `armeabi` (legacy ARMv5) slice
is never used at runtime regardless of alignment.

The real issue is the same class of problem `run.sh` already handles for
every other prebuilt app here: **all 31 of the `lib/arm64-v8a/*.so` entries
— the ones actually loaded on this device — are compressed**, which fails
`PackageManager`'s targetSdk 30+ requirement and would fail to load at
runtime if shipped verbatim. Unlike MtManager, iFlyIME has no known
anti-tamper code tied to its native libs, so there's no reason to expect
resigning (`default_dev_cert`, same path already used successfully for
adaway/Youtube/etc.) to cause a functional problem — it just needs the
standard decompress+resign pipeline, which `run.sh`'s existing
`has_preprocessed_issues()` check already detects and handles automatically.

**Decision: added as a new `run.sh` module (`ifkeyboard.apk`), taking the
normal default_dev_cert resign path.** No special-casing needed.
