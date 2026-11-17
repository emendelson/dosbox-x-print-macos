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
MIN_MACOS=12.0
ARCHS=(-arch arm64 -arch x86_64)

say() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- dylibs
if [ -d "$C/MacOS/arm64" ] || [ -d "$C/MacOS/x86_64" ]; then
    say "Merging per-architecture dylibs into Contents/Frameworks"
    mkdir -p "$C/Frameworks"
    libs=()
    for f in "$C/MacOS/arm64/"*.dylib; do libs+=("$(basename "$f")"); done

    # -change arguments mapping both old per-arch paths to the new location
    changes=()
    for lib in "${libs[@]}"; do
        [ -f "$C/MacOS/x86_64/$lib" ] || { echo "missing x86_64/$lib" >&2; exit 1; }
        for arch in arm64 x86_64; do
            changes+=(-change "@executable_path/$arch/$lib" "@executable_path/../Frameworks/$lib")
        done
    done

    for lib in "${libs[@]}"; do
        out="$C/Frameworks/$lib"
        lipo -create "$C/MacOS/arm64/$lib" "$C/MacOS/x86_64/$lib" -output "$out"
        install_name_tool -id "@executable_path/../Frameworks/$lib" "${changes[@]}" "$out"
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
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$plist"

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
