#!/bin/bash
#
# Prepares dosbox-x-print-SDL2.app for distribution on macOS:
#
#   * merges the per-architecture dylibs (MacOS/arm64, MacOS/x86_64) into
#     universal dylibs in Contents/Frameworks and relinks dosbox-x to them
#   * installs the launcher (macos/launcher.c) as the bundle executable and
#     moves the emulator to MacOS/dosbox-x-bin; the launcher keeps the
#     configuration in ~/Library/Application Support/DOSBox-X-Print
#   * optionally installs a universal nenscript (NENSCRIPT=path)
#   * compiles the Icon Composer icon (macos/AppIcon.icon) into Assets.car
#     and a fallback AppIcon.icns
#   * checks that every Mach-O file in the bundle is arm64 + x86_64
#   * signs everything inside-out with hardened runtime
#
# The script is idempotent: steps that were already applied are skipped.
#
# Usage:
#   macos/build-bundle.sh [path/to/dosbox-x-print-SDL2.app]
#
# Environment:
#   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc, for local testing).
#                  Use "Developer ID Application: ..." for a release, then
#                  notarize and staple the app.
#   NENSCRIPT      path to a universal nenscript binary to copy into Resources.
#                  nenscript 1.13.3 builds unchanged with:
#                    make CC="cc -arch arm64 -arch x86_64 -mmacosx-version-min=11.0"

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "${1:-$HERE/../dosbox-x-print-SDL2.app}" && pwd)"
C="$APP/Contents"
IDENTITY="${SIGN_IDENTITY:--}"
# Deployment target for the launcher and the icon. LSMinimumSystemVersion is
# set later to the highest minimum required by any binary in the bundle.
MIN_MACOS=12.0
ARCHS=(-arch arm64 -arch x86_64)

say() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- dylibs
if [ -d "$C/MacOS/arm64" ] || [ -d "$C/MacOS/x86_64" ]; then
    say "Merging per-architecture dylibs into Contents/Frameworks"
    mkdir -p "$C/Frameworks"
    # Pair each arm64 dylib with its x86_64 counterpart. Usually the names
    # match; when the two builds carry different versions of a library
    # (e.g. libx265.217 vs libx265.216) they are paired by the name before the
    # first dot and merged as <stem>.dylib.
    arm=() x86=() out=()
    for f in "$C/MacOS/arm64/"*.dylib; do
        a="$(basename "$f")"
        if [ -f "$C/MacOS/x86_64/$a" ]; then
            x="$a" o="$a"
        else
            stem="${a%%.*}"
            m=("$C/MacOS/x86_64/$stem".*.dylib)
            [ ${#m[@]} -eq 1 ] && [ -f "${m[0]}" ] ||
                { echo "no single x86_64 match for arm64/$a" >&2; exit 1; }
            x="$(basename "${m[0]}")" o="$stem.dylib"
            echo "    pairing arm64/$a with x86_64/$x as $o"
        fi
        arm+=("$a") x86+=("$x") out+=("$o")
    done
    n_x86=$(ls "$C/MacOS/x86_64/"*.dylib | wc -l)
    [ "$n_x86" -eq ${#arm[@]} ] || { echo "x86_64 has $n_x86 dylibs, arm64 has ${#arm[@]}" >&2; exit 1; }

    # -change arguments mapping both old per-arch paths to the new location
    changes=()
    for i in "${!arm[@]}"; do
        changes+=(-change "@executable_path/arm64/${arm[$i]}" "@executable_path/../Frameworks/${out[$i]}")
        changes+=(-change "@executable_path/x86_64/${x86[$i]}" "@executable_path/../Frameworks/${out[$i]}")
    done

    for i in "${!arm[@]}"; do
        dst="$C/Frameworks/${out[$i]}"
        lipo -create "$C/MacOS/arm64/${arm[$i]}" "$C/MacOS/x86_64/${x86[$i]}" -output "$dst"
        install_name_tool -id "@executable_path/../Frameworks/${out[$i]}" "${changes[@]}" "$dst"
    done
    main="$C/MacOS/dosbox-x"
    [ -f "$C/MacOS/dosbox-x-bin" ] && main="$C/MacOS/dosbox-x-bin"
    install_name_tool "${changes[@]}" "$main"
    rm -rf "$C/MacOS/arm64" "$C/MacOS/x86_64"
fi

# ---------------------------------------------------------------- launcher
if [ ! -f "$C/MacOS/dosbox-x-bin" ]; then
    say "Moving emulator to MacOS/dosbox-x-bin"
    mv "$C/MacOS/dosbox-x" "$C/MacOS/dosbox-x-bin"
fi
say "Building launcher"
xcrun clang "${ARCHS[@]}" -mmacosx-version-min=$MIN_MACOS -O2 -Wall -Wextra \
    -o "$C/MacOS/dosbox-x" "$HERE/launcher.c"

# ---------------------------------------------------------------- nenscript
if [ -n "${NENSCRIPT:-}" ]; then
    say "Installing nenscript from $NENSCRIPT"
    cp "$NENSCRIPT" "$C/Resources/nenscript"
    chmod 755 "$C/Resources/nenscript"
fi

# ---------------------------------------------------------------- icon
say "Compiling Icon Composer icon"
partial="$(mktemp -t dbxp-icon)"
xcrun actool "$HERE/AppIcon.icon" --compile "$C/Resources" \
    --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$partial" \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx \
    --minimum-deployment-target $MIN_MACOS \
    --output-format human-readable-text --errors --warnings >/dev/null
rm -f "$partial" "$C/Resources/dosbox-x.icns"
plist="$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$plist"

# Stray pre-bundle-format signature file; codesign --strict rejects it.
rm -f "$C/CodeResources"
find "$APP" -name .DS_Store -delete

# ---------------------------------------------------------------- arch check
say "Checking architectures"
bad=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        archs="$(lipo -archs "$f")"
        if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
            echo "  not universal: ${f#"$APP"/} ($archs)" >&2; bad=1
        fi
    fi
done < <(find "$APP" -type f -print0)
[ $bad -eq 0 ] || { echo "Some binaries are not universal." >&2; exit 1; }

# The app can't run on a system older than its most demanding binary.
min_os="$(find "$APP" -type f -print0 | while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    for a in arm64 x86_64; do
        vtool -arch "$a" -show-build "$f" 2>/dev/null | awk '$1 == "minos" { print $2 }'
    done
done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
say "Minimum macOS required by the bundled binaries: $min_os"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $min_os" "$plist"

# ---------------------------------------------------------------- signing
say "Signing with identity: $IDENTITY"
sign_opts=(--force --sign "$IDENTITY" --options runtime --entitlements "$HERE/entitlements.plist")
[ "$IDENTITY" != "-" ] && sign_opts+=(--timestamp)

for f in "$C/Frameworks/"*.dylib "$C/Resources/gs" "$C/Resources/gpcl6" "$C/Resources/nenscript"; do
    codesign "${sign_opts[@]}" "$f"
done
codesign "${sign_opts[@]}" "$C/Resources/BonjourEvents.app"
codesign "${sign_opts[@]}" "$C/MacOS/dosbox-x-bin"
codesign "${sign_opts[@]}" "$APP"

codesign --verify --strict --deep --verbose=1 "$APP"
say "Done: $APP"
