#!/bin/bash
#
# Builds GraphDigger as a universal (arm64 + x86_64) macOS application bundle.
#
#   ./scripts/build_universal.sh                  # release build + .app
#   ./scripts/build_universal.sh --dmg            # also produce a .dmg
#   ./scripts/build_universal.sh --debug          # debug configuration
#   ./scripts/build_universal.sh --min-os 11.0    # widen compatibility (see below)
#
# Deployment-target notes (measured on Xcode 27 / Swift 6.4):
#   * Swift Package Manager cannot express a macOS target below 12.0 — values
#     like .v10_15 or .v11 are silently raised — so Package.swift declares .v12
#     and the default build is minos 12.0.
#   * The toolchain itself bottoms out at macOS 11.0; nothing can produce
#     minos 10.x with this Xcode.
#   * `--min-os 11.0` adds explicit -target flags to both swiftc and clang to
#     reach 11.0. It costs a linker warning about mismatched object versions.
#
# Requirements: Xcode with the macOS SDK (xcodebuild -version must succeed).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="release"
MAKE_DMG=0
MIN_OS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --debug)    CONFIGURATION="debug" ;;
        --release)  CONFIGURATION="release" ;;
        --dmg)      MAKE_DMG=1 ;;
        --min-os)   MIN_OS="${2:-}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

APP_NAME="GraphDigger"
BUNDLE_ID="com.example.graphdigger"
EXECUTABLE_NAME="GraphDigger"
ARCHS=(arm64 x86_64)

# The version the bundle reports, in one place. Bump it with the release tag.
#
# It is not decoration: `ProjectHeader.appVersion` writes it into every saved
# project, and that field is the first thing wanted when a file misbehaves — so
# a bundle that keeps claiming an old number makes the one record that is
# supposed to identify the build useless. It sat at 0.1.0 across two releases
# before this line existed, which is how the problem went unnoticed.
VERSION="0.3.0"

# The project file type, read out of the source rather than typed again here.
#
# The identifier and the extension each appear twice: once in
# Sources/GDCore/ProjectFile.swift, which the save panels and the reader use, and
# once in the Info.plist below, which is what the Finder reads. A drift between
# them is silent and nasty — the app writes a file the Finder will not hand back
# on a double-click — so the plist is generated from the code instead of being
# kept in step by hand.
PROJECT_UTI="$(sed -n 's/.*typeIdentifier *= *"\([^"]*\)".*/\1/p' Sources/GDCore/ProjectFile.swift | head -1)"
PROJECT_EXT="$(sed -n 's/.*fileExtension *= *"\([^"]*\)".*/\1/p' Sources/GDCore/ProjectFile.swift | head -1)"
if [ -z "$PROJECT_UTI" ] || [ -z "$PROJECT_EXT" ]; then
    echo "error: could not read the project file type from Sources/GDCore/ProjectFile.swift" >&2
    exit 1
fi
echo "==> Project file type: .$PROJECT_EXT ($PROJECT_UTI)"

# ---------------------------------------------------------------- preflight
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: Xcode is required (xcodebuild not usable)." >&2
    echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

# Deployment target as Package.swift declares it; the actual minos of the
# produced binary is whatever the toolchain honours, read back below.
DECLARED_TARGET="12.0"
if grep -qE '\.v13' Package.swift; then DECLARED_TARGET="13.0"; fi
if grep -qE '\.v14' Package.swift; then DECLARED_TARGET="14.0"; fi
if grep -qE '\.v15' Package.swift; then DECLARED_TARGET="15.0"; fi

BUILD_ARGS=(-c "$CONFIGURATION")
for arch in "${ARCHS[@]}"; do BUILD_ARGS+=(--arch "$arch"); done

# SPM's product layout moved between toolchain versions; locate the binary
# rather than hard-coding one path.
find_executable() {
    local config_dir="$([ "$CONFIGURATION" = "release" ] && echo Release || echo Debug)"
    find "$REPO_ROOT/.build" -type f -name "$EXECUTABLE_NAME" \
        -path "*Products/$config_dir*" 2>/dev/null | head -1
}

STAGED_BINARIES=()
if [ -n "$MIN_OS" ]; then
    # A global -Xswiftc -target would override SPM's per-architecture target and
    # collapse both slices into one, so each architecture is built separately
    # and the slices are merged with lipo afterwards.
    echo "==> Overriding deployment target to macOS $MIN_OS (per-architecture builds)"
    DECLARED_TARGET="$MIN_OS"
    for arch in "${ARCHS[@]}"; do
        echo "    - $arch"
        rm -rf "$REPO_ROOT/.build/out"
        swift build -c "$CONFIGURATION" --arch "$arch" \
            -Xswiftc -target -Xswiftc "$arch-apple-macosx$MIN_OS" \
            -Xcc -target -Xcc "$arch-apple-macosx$MIN_OS"
        local_path="$(find_executable)"
        if [ -z "$local_path" ]; then
            echo "error: no $arch build product found" >&2
            exit 1
        fi
        staged="$REPO_ROOT/.build/staged-$arch"
        cp "$local_path" "$staged"
        STAGED_BINARIES+=("$staged")
    done
    echo "==> Merging slices"
    EXECUTABLE_PATH="$REPO_ROOT/.build/staged-universal"
    lipo -create "${STAGED_BINARIES[@]}" -output "$EXECUTABLE_PATH"
else
    echo "==> Building $APP_NAME ($CONFIGURATION) for ${ARCHS[*]}, macOS $DECLARED_TARGET+"
    swift build "${BUILD_ARGS[@]}"
    EXECUTABLE_PATH="$(find_executable)"
fi

if [ -z "${EXECUTABLE_PATH:-}" ] || [ ! -f "$EXECUTABLE_PATH" ]; then
    echo "error: could not locate the built executable under .build" >&2
    exit 1
fi

DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# ------------------------------------------------------------- bundle layout
echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>$DECLARED_TARGET</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key>   <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <!-- The project, and the reason the format exists: someone who has
                 this app and nothing else can double-click a .gdproj and see
                 the whole session — image, calibration and curves. Owner rank
                 because this app is the only thing that can read one. -->
            <key>CFBundleTypeName</key>      <string>GraphDigger Project</string>
            <key>CFBundleTypeRole</key>      <string>Editor</string>
            <key>LSHandlerRank</key>         <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>$PROJECT_UTI</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>$PROJECT_EXT</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>      <string>Chart Image</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <!-- Declared rather than deduced from the extension: an exported
                 declaration is what makes the identifier below resolve on the
                 machine of whoever receives the file, which is the entire point
                 of a project format. Both strings were read out of
                 Sources/GDCore/ProjectFile.swift at the top of this script, so
                 this plist cannot drift from the code that writes the files.
                 (No backticks in here, and no dollar signs except the variables
                 above: this heredoc is unquoted, so a backtick would run as a
                 command and a stray dollar would be expanded.) -->
            <key>UTTypeIdentifier</key>      <string>$PROJECT_UTI</string>
            <key>UTTypeDescription</key>     <string>GraphDigger Project</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>$PROJECT_EXT</string>
                </array>
                <key>public.mime-type</key>
                <string>application/x-graphdigger-project</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# ------------------------------------------------------------------- signing
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null \
    || echo "    (codesign failed; the app may still run on this machine)"

# ------------------------------------------------------------------ reporting
echo
echo "==> Result"
lipo -info "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
for arch in "${ARCHS[@]}"; do
    minos="$(vtool -arch "$arch" -show-build \
        "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null \
        | awk '/minos/ {print $2; exit}')"
    printf '    %-7s minos %s\n' "$arch" "${minos:-unknown}"
done
echo "    bundle size : $(du -sh "$APP_BUNDLE" | cut -f1)"

if [ "$MAKE_DMG" = "1" ]; then
    DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
    echo "==> Creating $DMG_PATH"
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" \
        -ov -format UDZO "$DMG_PATH" >/dev/null
    echo "    dmg size    : $(du -sh "$DMG_PATH" | cut -f1)"
fi

echo
echo "Done: $APP_BUNDLE"
echo "Run it with:  open \"$APP_BUNDLE\""
