export ANDROID_BUILD_TOP=/home/android/evo-11.9
#!/bin/bash
set -e

# Configuration
OUTPUT_DIR="extra-apps"

# Modules whose bundled bytecode is known to hard-fail dex2oatd's verifier
# (obfuscated/malformed classes, e.g. abstract/native constructors) -- this is a
# property of the specific binary, not the device or build config, so it will
# reproduce identically anywhere these same APKs are built. dex_preopt must be
# disabled for these or the whole ninja build aborts.
DEX_PREOPT_DISABLED=("freenovel" "sogou" "Gboard" "message" "kasa" "reddit" "tether" "messenger" )

# Per-module overrides for properties that can't be derived from the APK itself
# (policy decisions, not manifest facts).
#   Gboard needs privileged:true + overrides:["LatinIME"] + compile_multilib:"64"
#   or it crashes on launch (missing privileged perms / wrong-arch native libs) --
#   CONFIRMED via device testing 2026-08-27.
#   MtManager: REMOVED from the build entirely 2026-08-27 -- see
#   OFFICIAL_APK_NOTES.md. Its anti-tamper native libs (libmtprotect.so/
#   libhook.so) require an untouched signature to pass, but /product is
#   EROFS so compressed JNI libs must be decompressed (breaking the
#   signature) to work at all baked into the ROM. No config here can satisfy
#   both. Install the official apk post-boot via `adb install` instead.
#   add xml file to fix issues
#declare -A PRIVILEGED_APPS=(["Gboard"]=1)
# filemanager (File Manager+) is NOT built in: it ships in install/ and is
# installed as a normal user app. The SYSTEM_DOCUMENT_MANAGER role goes only to a
# system app with an OPEN_DOCUMENT handler, and only when there is exactly one
# ("There should be exactly one documenter; found 2"). With File Manager+ built
# in beside DocumentsUIGoogle the role has no holder, DocumentsUI lacks
# CACHE_CONTENT, and saving through the picker crashes (Duck Detector,
# 2026-09-30). CACHE_CONTENT is signature|role, so no privapp xml can grant it.
declare -A OVERRIDES_APPS=(["Gboard"]="LatinIME" ["message"]="messaging")

# Modules needing a /product/etc/permissions/privapp-permissions-*.xml allowlist
# (required for ANY privileged app requesting signature|privileged permissions --
# without this the permissions are silently denied even if privileged:true).
# Maps module name -> xml filename in this directory.
declare -A PRIVAPP_PERMISSIONS_XML=(["Gboard"]="privapp-permissions-gboard.xml")
# NOTE: compile_multilib has no effect on android_app_import (no compilation happens for a
# prebuilt import -- confirmed 2026-08-27 while diagnosing MtManager, which still crashed
# with this set). Kept only for Gboard since it's part of the already-confirmed-working
# config and untouched on that basis, not because it's known to matter.
declare -A COMPILE_MULTILIB_64=(["Gboard"]=1)

# Apps whose own signing certificate is load-bearing for something other than the
# apk's own install (e.g. a kernel driver's expected-manager-signature check, common
# for root manager apps) -- for these, preserve the original signature even if the
# apk has compressed JNI libs, rather than taking the default_dev_cert re-sign path.
#
# ksu33 (KernelSU-Next manager) is NOT in this list, despite needing signature
# matching for the kernel's EXPECTED_MANAGER_HASH check -- REVERTED 2026-08-27.
# The "no dlopen crash observed" note below was wrong: it was only ever tested
# while ksu33 was on default_dev_cert (which decompresses JNI libs as a side
# effect), never on the presigned/skip_preprocessed_apk_checks path. On real
# hardware (lin22/crosshatch) that combination crash-loops on
# `dlopen failed: library "libkernelsu.so" not found` -- confirmed via logcat.
# The two constraints (dlopen needs decompressed libs; kernel trust needs a
# signature match) are NOT actually in conflict, since we build the kernel
# ourselves: take default_dev_cert (fixes dlopen), then repoint the kernel's
# KSU_NEXT_MANAGER_SIZE/KSU_NEXT_MANAGER_HASH (drivers/kernelsu/Kbuild) at the
# resigned apk's own certificate instead of upstream's default. See
# ksu33_manager_cert.sh in this directory for computing those values.
#
# RevancedManagerPlus: official apk from ~/offical has zero compression
# issues (no compressed lib/*.so, resources.arsc already stored+aligned) --
# preserving its signature is both safe and simpler than resigning, no
# functional reason to touch it.
declare -A PRESERVE_SIGNATURE_APPS=(["RevancedManagerPlus"]=1)

# Apps needing the compressed-JNI resign path (see has_native_lib_issues below)
# but where default_dev_cert:true is WRONG: that shares a cert with every other
# default_dev_cert app in the build, and a kernel driver doing manager-signature
# detection (KernelSU-Next) can't tell them apart -- CONFIRMED 2026-08-30 on
# crosshatch, where the scan crowned Aperture.apk (also default_dev_cert) as
# "the manager" instead of KernelSUNext.apk. Maps module name -> the name of an
# android_app_certificate Soong module (declared per-device, e.g.
# device/google/crosshatch/security/ksu_manager/Android.bp) providing a
# dedicated cert instead.
declare -A CUSTOM_CERTIFICATE_APPS=(["KernelSUNext"]="ksu_manager_cert")

# A free-text note emitted inside a module's own block, for cases where the
# generated Android.bp would otherwise look incomplete. KernelSUNext is the one
# such case: its native helper libksud.so is installed by a PRODUCT_COPY_FILES
# line in each device.mk (to /product/app/KernelSUNext/lib/arm64/), NOT by a
# Soong "required:" dependency -- an earlier cc_prebuilt_binary attempt was
# rejected because relative_install_path may not escape the module's install
# dir. Without this note the missing "required:" reads like an oversight.
declare -A MODULE_NOTES=(["KernelSUNext"]=$'    // libksud.so gets shipped separately via PRODUCT_COPY_FILES in device.mk,\n    // not a Soong "required" module -- see the comment there.')

# ksu_script.sh (a boot script run by sunfish's ksu-autoinstall) bind-mounts an
# empty dir over every app in this directory, so the ROM copy disappears and a
# newer version can be installed as a normal user app -- a baked-in system app
# can otherwise only be upgraded by an apk signed with the same key, which the
# resigned ones here never are. run.sh regenerates the hide_path lines from the
# apks present, replacing the hide_path calls in the ksu_script.sh template.
# Not hidden:
#   RevancedManagerPlus: keeps its own signature, so it upgrades in place.
#   KernelSUNext: the kernel only trusts a manager with this build's own cert
#     (see CUSTOM_CERTIFICATE_APPS), so hiding it leaves no usable manager.
# .apks app sets (Gboard, Line) are not hidden either: Gboard replaces LatinIME,
# so hiding it leaves the device with no keyboard.
# Opt-in now: apps keep their own signature (see extract_jni_libs), so they
# update in place and nothing needs hiding. List a module here only to force a
# baked-in app out of the way, e.g. one shipped with a foreign signature.
declare -A HIDE_APPS=()
HIDE_LINES=""

# Ensure Android Build Tools (aapt2) are accessible
if ! command -v aapt2 &> /dev/null; then
    # Fallback to look inside your active AOSP source tree environment if not in path
    if [ -n "$ANDROID_BUILD_TOP" ]; then
        AAPT2_PATH=$(find "$ANDROID_BUILD_TOP/prebuilts" -name aapt2 -type f -executable | head -n 1)
    fi
fi

AAPT2_CMD=${AAPT2_PATH:-aapt2}

if ! command -v "$AAPT2_CMD" &> /dev/null; then
    echo "❌ Error: 'aapt2' utility not found. Please run 'source build/envsetup.sh' first."
    exit 1
fi

# Ensure zipalign is accessible too (needed for the preprocessed-apk checks below)
if ! command -v zipalign &> /dev/null; then
    if [ -n "$ANDROID_BUILD_TOP" ]; then
        ZIPALIGN_PATH=$(find "$ANDROID_BUILD_TOP/prebuilts" -name zipalign -type f -executable | head -n 1)
    fi
fi
ZIPALIGN_CMD=${ZIPALIGN_PATH:-zipalign}

if ! command -v "$ZIPALIGN_CMD" &> /dev/null; then
    echo "❌ Error: 'zipalign' utility not found. Please run 'source build/envsetup.sh' first."
    exit 1
fi

# Mirrors build/soong/scripts/check_prebuilt_presigned_apk.py's has_preprocessed_issues():
# returns success (0) if the apk would FAIL Soong's preprocessed-apk check (misaligned zip
# entries or compressed lib/*.so), i.e. if skip_preprocessed_apk_checks is needed.
has_preprocessed_issues() {
    local apk="$1"
    if ! "$ZIPALIGN_CMD" -c -p 4 "$apk" >/dev/null 2>&1; then
        return 0
    fi
    python3 - "$apk" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    for info in zf.infolist():
        if info.filename.startswith('lib/') and info.filename.endswith('.so') and info.compress_type != zipfile.ZIP_STORED:
            sys.exit(0)
sys.exit(1)
PYEOF
}

# A preinstalled (system) app's native libs are never extracted by
# PackageManager -- it looks for them in <app dir>/lib/<isa>/ -- so an apk that
# ships them compressed (extractNativeLibs=true) must have them unpacked there
# at build time. That is how OEM preinstalls keep the developer's signature
# (and so remain updatable) without an uncompressed-libs build of the apk. The
# libs land via PRODUCT_COPY_FILES in the generated jni-libs.mk (ELF copies need
# BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true in the device's
# BoardConfig), the same route KernelSUNext's libksud.so takes.
# $1 = apk, $2 = module name. One ABI: arm64-v8a if present, else 32-bit ARM.
extract_jni_libs() {
    local apk="$1" mod="$2" abi isa
    if unzip -Z1 "$apk" 'lib/arm64-v8a/*.so' >/dev/null 2>&1; then abi=arm64-v8a; isa=arm64
    elif unzip -Z1 "$apk" 'lib/armeabi-v7a/*.so' >/dev/null 2>&1; then abi=armeabi-v7a; isa=arm
    elif unzip -Z1 "$apk" 'lib/armeabi/*.so' >/dev/null 2>&1; then abi=armeabi; isa=arm
    else return 0
    fi
    mkdir -p "$OUTPUT_DIR/prebuilt/jni/$mod/$isa"
    unzip -qjo "$apk" "lib/$abi/*.so" -d "$OUTPUT_DIR/prebuilt/jni/$mod/$isa"
    local so
    for so in "$OUTPUT_DIR/prebuilt/jni/$mod/$isa"/*.so; do
        echo "PRODUCT_COPY_FILES += \$(EXTRA_APPS_JNI_DIR)/$mod/$isa/${so##*/}:\$(TARGET_COPY_OUT_PRODUCT)/app/$mod/lib/$isa/${so##*/}" >> "$OUTPUT_DIR/jni-libs.mk"
    done
    echo "   unpacked $(ls "$OUTPUT_DIR/prebuilt/jni/$mod/$isa" | wc -l) $abi libs"
}

echo "🚀 Starting User APK extraction and conversion pipeline..."

# 1. Initialize folders
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/prebuilt"
mkdir -p "$OUTPUT_DIR/sepolicy"

# Start creating the base blueprint file
cat << 'EOF' > "$OUTPUT_DIR/prebuilt/Android.bp"
// Automatically generated user prebuilt mapping for EROFS execution
EOF

# Native libs of preinstalled apps that ship them compressed (extract_jni_libs).
# Include from the device's product makefile:
#   -include <path to extra-apps>/jni-libs.mk
cat << 'EOF' > "$OUTPUT_DIR/jni-libs.mk"
# Generated by ~/extraAPKs/run.sh -- native libs of preinstalled apps that
# ship them compressed, unpacked to /product/app/<app>/lib/<isa>/ so the apk
# itself stays untouched (own signature, updatable). Needs
# BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true.
EXTRA_APPS_JNI_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))/prebuilt/jni
EOF

# Start creating the file contexts tracking manifest
cat << 'EOF' > "$OUTPUT_DIR/sepolicy/file_contexts"
# Automatically generated SELinux mapping for custom user apps
EOF

# 2. Process each APK in the current working directory
for apk in *.apk; do
    [ -e "$apk" ] || continue
    
    echo "------------------------------------------------"
    echo "🔍 Processing: $apk"
    
    # Extract the clean file base name
    filename=$(basename -- "$apk")
    base_name="${filename%.*}"
    # Format a valid Soong Module Name (alphanumeric and underscores only)
    module_name=$(echo "$base_name" | sed -e 's/[^a-zA-Z0-9_]/_/g')

    # Read the explicit Android Manifest Package Name using aapt2
    echo "📦 Extracting package metadata..."
    package_name=$("$AAPT2_CMD" dump packagename "$apk")

    if [ -z "$package_name" ]; then
        echo "⚠️ Warning: Could not read package name for $apk. Skipping."
        continue
    fi
    echo "📌 Package ID resolved: $package_name"
    # remove prepackage app from android
    #adb uninstall $package_name  || true
    # Copy the binary to the destination tree
    cp "$apk" "$OUTPUT_DIR/prebuilt/$filename"

    # Read <uses-library> tags and targetSdkVersion from the manifest
    badging_output=$("$AAPT2_CMD" dump badging "$apk" 2>/dev/null)
    target_sdk=$(echo "$badging_output" | grep -oP "targetSdkVersion:'\K[0-9]+" | head -n 1)
    # NOTE: manifest_check.py requires the optional/required lib lists to match the
    # manifest's *order* exactly (not just as a set), so dedupe without sorting.
    required_libs=$(echo "$badging_output" | grep -oP "uses-library:'\K[^']+" | awk '!seen[$0]++')
    optional_libs=$(echo "$badging_output" | grep -oP "uses-library-not-required:'\K[^']+" | awk '!seen[$0]++')

    # Soong's android_app_import has exactly two ways to handle a presigned apk with
    # targetSdkVersion>=30 (which android.content.pm enforces must be v2/v3-signed):
    #   preprocessed:true  -> plain `cp` of the ORIGINAL bytes (see app_import.go:394-404).
    #                         Only correct if the source apk was ALREADY decompressed+aligned
    #                         before ITS OWN v2 signature was applied (true for Google's own
    #                         Gboard/GMS builds, per go/gms-uncompressed-jni-slides -- NOT true
    #                         for arbitrary third-party/cracked apks).
    #   (no presigned/preprocessed) + default_dev_cert:true -> Soong decompresses embedded JNI
    #                         libs THEN signs that output with PRODUCT_DEFAULT_DEV_CERTIFICATE
    #                         (app_import.go:405-419, uses the *decompressed* jnisUncompressed).
    # `skip_preprocessed_apk_checks` on the first path does NOT fix anything -- it only silences
    # the build-time warning while shipping the still-compressed .so verbatim, which fails at
    # runtime with `dlopen failed: library "lib*.so" not found` (confirmed via device logcat on
    # MtManager 2026-08-27: the installed apk's libmtprotect.so was still `Defl:N`, not `stor`).
    # So: compressed JNI -> always take the resign path, regardless of target_sdk. This drops the
    # original vendor's signing identity, but none of these apps have any update path depending on
    # signature continuity, so it's a fine trade for actually-working native libs.
    has_native_lib_issues=false
    if has_preprocessed_issues "$apk"; then
        has_native_lib_issues=true
    fi

    preserve_signature=false
    if [ -n "${PRESERVE_SIGNATURE_APPS[$module_name]:-}" ]; then
        preserve_signature=true
    fi

    skip_check_line=""
    embedded_libs_line=""
    # Resign only when the app must carry a specific cert (KernelSUNext: the
    # kernel pins it). Every other app keeps the developer's own signature --
    # otherwise its real updates (Play, ReVanced Manager, a newer apk) are
    # refused as a signature mismatch, which is what hiding used to work
    # around. Compressed JNI libs are handled the way preinstalled OEM apps do
    # it instead: unpacked next to the untouched apk (see extract_jni_libs).
    if [ "$has_native_lib_issues" = true ] && [ -n "${CUSTOM_CERTIFICATE_APPS[$module_name]:-}" ]; then
        presigned_line=""
        preprocessed_line=""
        # NOTE 2026-09-02: use_embedded_native_libs is NOT a recognized android_app_import
        # property on this Soong version ("unrecognized property" build error) -- reverted.
        # The native-lib-not-found runtime issue this was meant to fix is still open.
        cert_module="${CUSTOM_CERTIFICATE_APPS[$module_name]}"
        echo "⚠️  $filename ships misaligned/compressed native libs; re-signing with dedicated cert '$cert_module' instead of preserving its own signature"
        cert_line=$'\n    certificate: ":'"$cert_module"'", // Compressed JNI libs meant preprocessed:true would ship them broken (see run.sh comments); Soong re-signs the decompressed output instead. Dedicated cert (not default_dev_cert) so this app'"'"'s signature stays distinguishable from every other resigned app -- see CUSTOM_CERTIFICATE_APPS comment. Leading ":" is required for Soong to resolve this as a local android_app_certificate module instead of a bare default_dev_cert-style path.'
    else
        if [ "$has_native_lib_issues" = true ]; then
            echo "⚠️  $filename ships misaligned/compressed native libs; keeping its own signature, libs unpacked to /product/app/$module_name/lib/"
            skip_check_line=$'\n    skip_preprocessed_apk_checks: true, // Shipped verbatim to keep its own signature (so it can be updated); its compressed JNI libs are unpacked beside it by jni-libs.mk, see extract_jni_libs in run.sh'
            extract_jni_libs "$apk" "$module_name"
        fi
        presigned_line=$'\n    presigned: true,'
        cert_line=""
        # Always verbatim, whatever the targetSdk. With preprocessed:false Soong
        # zipaligns the apk, which drops its v2/v3 signing block; the v1 JAR
        # signature left behind says v2 was used (X-Android-APK-Signed), so it
        # fails verification as "signature stripped" and the app does not
        # install (seen on MicroG, targetSdk 29, 2026-09-25).
        if [ "$has_native_lib_issues" = true ]; then
            preprocessed_line=$'\n    preprocessed: true, // Shipped verbatim to keep its own signature; its compressed libs are unpacked beside it (jni-libs.mk)'
        else
            preprocessed_line=$'\n    preprocessed: true, // Already properly aligned/uncompressed; safe to ship verbatim'
        fi
    fi

    uses_libs_line=""
    if [ -n "$required_libs" ]; then
        libs_csv=$(echo "$required_libs" | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')
        uses_libs_line=$'\n    uses_libs: ['"$libs_csv"'],'
    fi

    optional_uses_libs_line=""
    if [ -n "$optional_libs" ]; then
        libs_csv=$(echo "$optional_libs" | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')
        optional_uses_libs_line=$'\n    optional_uses_libs: ['"$libs_csv"'],'
    fi

    dex_preopt_enabled="true"
    for bad in "${DEX_PREOPT_DISABLED[@]}"; do
        # case-insensitive: renaming FreeNovel.apk to freenovel.apk silently re-enabled preopt
        if [ "${module_name,,}" = "${bad,,}" ]; then
            echo "⚠️  $filename is a known dex2oatd verifier hard-failure; disabling dex_preopt"
            dex_preopt_enabled="false"
            break
        fi
    done

    privileged_val="false"
    if [ -n "${PRIVILEGED_APPS[$module_name]:-}" ]; then
        privileged_val="true"
    fi

    overrides_line=""
    if [ -n "${OVERRIDES_APPS[$module_name]:-}" ]; then
        overrides_line=$'\n    overrides: ["'"${OVERRIDES_APPS[$module_name]}"'"],'
    fi

    multilib_line=""
    if [ -n "${COMPILE_MULTILIB_64[$module_name]:-}" ]; then
        multilib_line=$'\n    compile_multilib: "64",'
    fi

    note_line=""
    if [ -n "${MODULE_NOTES[$module_name]:-}" ]; then
        note_line=$'\n'"${MODULE_NOTES[$module_name]:-}"
    fi

    # 3. Append to the centralized Soong Android.bp
    cat << EOF >> "$OUTPUT_DIR/prebuilt/Android.bp"

android_app_import {
    name: "$module_name",
    apk: "$filename",${presigned_line}${preprocessed_line}${cert_line}${skip_check_line}${embedded_libs_line}
    privileged: $privileged_val,${overrides_line}
    product_specific: true,${uses_libs_line}${optional_uses_libs_line}${multilib_line}
    dex_preopt: {
        enabled: $dex_preopt_enabled,
    },${note_line}
}
EOF

    # 4. Append to the centralized SELinux file_contexts manifest
    # Maps the binary folder inside the read-only /product EROFS cluster
    cat << EOF >> "$OUTPUT_DIR/sepolicy/file_contexts"
/product/app/$module_name(/.*)?          u:object_r:system_file:s0
EOF

    if [ -n "${HIDE_APPS[$module_name]:-}" ]; then
        app_dir=app
        [ "$privileged_val" = true ] && app_dir=priv-app
        HIDE_LINES+="hide_path /product/$app_dir/$module_name /dev/empty_$module_name"$'\n'
    fi

    # 5. If this module needs a privapp-permissions allowlist, copy it in and
    # emit a prebuilt_etc module for it (installs to /product/etc/permissions/).
    if [ -n "${PRIVAPP_PERMISSIONS_XML[$module_name]:-}" ]; then
        xml_file="${PRIVAPP_PERMISSIONS_XML[$module_name]}"
        cp "$xml_file" "$OUTPUT_DIR/prebuilt/$xml_file"
        cat << EOF >> "$OUTPUT_DIR/prebuilt/Android.bp"

prebuilt_etc {
    name: "$xml_file",
    src: "$xml_file",
    sub_dir: "permissions",
    product_specific: true,
}
EOF
    fi

done

# 2a. Process any .apks (bundletool APK Set) files as android_app_set modules.
# Use this for apps that ship as density/config splits (e.g. from an .apkm bundle) --
# android_app_import's plain `apk:` property only accepts one monolithic file, and a
# base-only split is often missing resources that live in the density-specific splits
# (confirmed 2026-08-27 on Gboard: a dangling drawable reference only resolved once the
# matching density split was included). See build_gboard_apks.py for how a bundletool-
# compatible toc.pb gets hand-built from loose split apks pulled out of an .apkm archive.
for apkset in *.apks; do
    [ -e "$apkset" ] || continue

    echo "------------------------------------------------"
    echo "🔍 Processing: $apkset"

    filename=$(basename -- "$apkset")
    base_name="${filename%.*}"
    module_name=$(echo "$base_name" | sed -e 's/[^a-zA-Z0-9_]/_/g')

    cp "$apkset" "$OUTPUT_DIR/prebuilt/$filename"

    privileged_val="false"
    if [ -n "${PRIVILEGED_APPS[$module_name]:-}" ]; then
        privileged_val="true"
    fi

    overrides_line=""
    if [ -n "${OVERRIDES_APPS[$module_name]:-}" ]; then
        overrides_line=$'\n    overrides: ["'"${OVERRIDES_APPS[$module_name]}"'"],'
    fi

    cat << EOF >> "$OUTPUT_DIR/prebuilt/Android.bp"

android_app_set {
    name: "$module_name",
    set: "$filename",
    privileged: $privileged_val,${overrides_line}
    product_specific: true,
}
EOF

    cat << EOF >> "$OUTPUT_DIR/sepolicy/file_contexts"
/product/app/$module_name(/.*)?          u:object_r:system_file:s0
EOF

    # If this module needs a privapp-permissions allowlist, copy it in and
    # emit a prebuilt_etc module for it (installs to /product/etc/permissions/).
    if [ -n "${PRIVAPP_PERMISSIONS_XML[$module_name]:-}" ]; then
        xml_file="${PRIVAPP_PERMISSIONS_XML[$module_name]}"
        cp "$xml_file" "$OUTPUT_DIR/prebuilt/$xml_file"
        cat << EOF >> "$OUTPUT_DIR/prebuilt/Android.bp"

prebuilt_etc {
    name: "$xml_file",
    src: "$xml_file",
    sub_dir: "permissions",
    product_specific: true,
}
EOF
    fi

done

# 2b. Include the busybox binary, if present, as a cc_prebuilt_binary
if [ -e "busybox" ]; then
    echo "------------------------------------------------"
    echo "🔍 Processing: busybox"
    cp "busybox" "$OUTPUT_DIR/prebuilt/busybox"
    cat << 'EOF' >> "$OUTPUT_DIR/prebuilt/Android.bp"

cc_prebuilt_binary {
    name: "busybox",
    srcs: ["busybox"],
    product_specific: true,    // Installs to /product/bin/busybox
    strip: {
        none: true,            // Keeps the binary from being stripped of symbols
    },
}
EOF
fi

# 2c. Precopy: every apk in copy/ ships in /product/etc/precopy/ and is copied
# to Download/precopy/ on the device at boot (scripts/precopy.sh), so it can be
# installed without downloading it. prebuilt_etc, not PRODUCT_COPY_FILES: the
# build refuses .apk files there ("Prebuilt apk found in PRODUCT_COPY_FILES").
# The source is renamed to its module name so device.mk can derive the module
# name from the filename; `filename` restores the original name on the device.
mkdir -p "$OUTPUT_DIR/prebuilt/precopy"
for apk in copy/*.apk; do
    [ -s "$apk" ] || continue
    filename=$(basename -- "$apk")
    module_base=$(echo "${filename%.*}" | sed -e 's/[^a-zA-Z0-9_]/_/g')
    echo "------------------------------------------------"
    echo "📥 Precopy: $filename"
    cp "$apk" "$OUTPUT_DIR/prebuilt/precopy/$module_base.apk"
    cat << EOF >> "$OUTPUT_DIR/prebuilt/Android.bp"

prebuilt_etc {
    name: "precopy_$module_base",
    src: "precopy/$module_base.apk",
    filename: "$filename",
    sub_dir: "precopy",
    product_specific: true,
}
EOF
done

# 2c'. User apps: every apk in install/ ships untouched in
# /product/etc/install-apps/ and is installed as a normal user app (pm install)
# on the device once setup wizard is done (scripts/install-apps.sh). Unlike the
# system apps above, these keep the developer's own signature, so Play (or a
# newer apk) updates them in place. A baked-in system app that had to be
# resigned (compressed JNI libs, see above) can never take the real update
# without being uninstalled first, which a system app cannot be.
mkdir -p "$OUTPUT_DIR/prebuilt/install-apps"
for apk in install/*.apk; do
    [ -s "$apk" ] || continue
    filename=$(basename -- "$apk")
    module_base=$(echo "${filename%.*}" | sed -e 's/[^a-zA-Z0-9_]/_/g')
    echo "------------------------------------------------"
    echo "📲 Install as user app: $filename"
    cp "$apk" "$OUTPUT_DIR/prebuilt/install-apps/$module_base.apk"
    cat << EOF >> "$OUTPUT_DIR/prebuilt/Android.bp"

prebuilt_etc {
    name: "userapp_$module_base",
    src: "install-apps/$module_base.apk",
    filename: "$filename",
    sub_dir: "install-apps",
    product_specific: true,
}
EOF
done

# 2d. Boot scripts for sunfish's ksu-autoinstall (run on every boot from
# /product/etc/ksu-autoinstall/scripts/); publish.sh copies them into
# device/google/sunfish/ksu-autoinstall/scripts/.
mkdir -p "$OUTPUT_DIR/scripts"
HIDE_LINES="$HIDE_LINES" awk '
    /^hide_path \// { if (!done) { printf "%s", ENVIRON["HIDE_LINES"]; done = 1 } next }
    { print }
    END { if (!done) exit 1 }
' ksu_script.sh > "$OUTPUT_DIR/scripts/ksu_script.sh" || {
    echo "❌ Error: ksu_script.sh has no hide_path calls to replace"; exit 1; }
echo "------------------------------------------------"
echo "🙈 ksu_script.sh hides:"
printf '%s' "$HIDE_LINES" | sed 's/^/     /'

cat << 'EOF' > "$OUTPUT_DIR/scripts/precopy.sh"
#!/system/bin/sh
#
# Copy the apks this ROM ships in /product/etc/precopy/ to Download/precopy/,
# so they can be installed without downloading them. Generated by
# ~/extraAPKs/run.sh from its copy/ directory.
#
# Run on every boot by ksu-autoinstall.sh. Each apk is copied once per wipe
# (the marker lives in /data/adb), so one the user deleted stays deleted, and
# a new filename -- e.g. a version bump -- is copied again.
(
SRC=/product/etc/precopy
DL=/data/media/0/Download
DST=$DL/precopy
STATE=/data/adb/.ksu-autoinstall
LOG=/data/adb/ksu-autoinstall.log

[ -d "$SRC" ] || exit 0

# /data/media/0 is file-based-encrypted until user 0 unlocks, and Download
# only appears once the media stack has created it: wait on a fresh wipe.
i=0
while [ ! -d "$DL" ] && [ "$i" -lt 300 ]; do
	sleep 2
	i=$((i + 1))
done
[ -d "$DL" ] || exit 0
mkdir -p "$STATE" "$DST" || exit 0

# Match Download's owner, or the media stack (and so file managers) may not be
# able to read what root wrote.
owner=$(stat -c %u:%g "$DL")
chown "$owner" "$DST"
chmod 0771 "$DST"

for apk in "$SRC"/*.apk; do
	[ -f "$apk" ] || continue
	name=${apk##*/}
	[ -f "$STATE/precopy-$name.done" ] && continue
	if cp "$apk" "$DST/$name.tmp" && mv "$DST/$name.tmp" "$DST/$name"; then
		chown "$owner" "$DST/$name"
		chmod 0664 "$DST/$name"
		: > "$STATE/precopy-$name.done"
		echo "$(date) precopied $name" >> "$LOG"
	else
		rm -f "$DST/$name.tmp"
		echo "$(date) FAILED to precopy $name" >> "$LOG"
	fi
done
restorecon -R "$DST" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
EOF

cat << 'EOF' > "$OUTPUT_DIR/scripts/install-apps.sh"
#!/system/bin/sh
#
# Install the apks this ROM ships in /product/etc/install-apps/ as normal user
# apps, once setup wizard is done. Generated by ~/extraAPKs/run.sh from its
# install/ directory. They keep their own signature, so they update normally.
#
# Run on every boot by ksu-autoinstall.sh. Each apk is installed once per wipe
# (marker in /data/adb); a failed install retries on the next boot. An app the
# user already has at the same or a newer version counts as done.
(
SRC=/product/etc/install-apps
STATE=/data/adb/.ksu-autoinstall
LOG=/data/adb/ksu-autoinstall.log
log() {
	echo "$(date +%H:%M:%S) - $*" >> "$LOG"
}

[ -d "$SRC" ] || exit 0
mkdir -p "$STATE" || exit 0

pending=0
for apk in "$SRC"/*.apk; do
	[ -f "$STATE/userapp-${apk##*/}.done" ] || pending=$((pending + 1))
done
[ "$pending" -gt 0 ] || exit 0

# Installing during setup wizard competes with it (and the first boot after a
# wipe reboots right after boot_completed to activate the KernelSU modules).
while [ "$(settings get global device_provisioned 2>/dev/null)" != "1" ]; do
	sleep 5
done
log "[USER APPS] Installing $pending app(s) from $SRC..."

for apk in "$SRC"/*.apk; do
	[ -f "$apk" ] || continue
	name=${apk##*/}
	[ -f "$STATE/userapp-$name.done" ] && continue
	out=$(pm install -r --user 0 "$apk" 2>&1)
	case "$out" in
		*Success*)
			: > "$STATE/userapp-$name.done"
			log "[USER APP] Installed $name" ;;
		*VERSION_DOWNGRADE*|*UPDATE_INCOMPATIBLE*)
			: > "$STATE/userapp-$name.done"
			log "[USER APP] $name: user already has its own install ($out)" ;;
		*)
			log "[FAILED] User app $name: $out" ;;
	esac
done
log "[USER APPS] Done."
) </dev/null >/dev/null 2>&1 &
EOF

# 5. Create the companion companion SELinux build bridge
cat << 'EOF' > "$OUTPUT_DIR/sepolicy/Android.mk"
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
BOARD_VENDOR_SEPOLICY_DIRS += $(LOCAL_PATH)
EOF

echo "------------------------------------------------"
echo "✅ Success! Copy the generated '$OUTPUT_DIR' folder straight into your LineageOS root source tree."
