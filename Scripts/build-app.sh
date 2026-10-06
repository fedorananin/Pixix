#!/bin/zsh
# Builds, assembles and signs Pixix.app. Nothing is written inside the project folder.
#
#   Scripts/build-app.sh             build into ~/Library/Caches/Pixix/dist/Pixix.app
#   Scripts/build-app.sh --install   also copy the app to /Applications and make it the default image viewer
#   Scripts/build-app.sh --install --keep-defaults   install without touching which app opens images
#   Scripts/build-app.sh --zip       also pack dist/Pixix.zip, the file attached to a release
#   Scripts/build-app.sh --debug     unoptimized build, for debugging
#
# Signing: the certificate named by PIXIX_SIGN_IDENTITY, else "Local Dev" if the keychain has it,
# else an ad hoc signature. Set PIXIX_SIGN_IDENTITY=- to force ad hoc.
# PIXIX_CACHE overrides where build output goes.
set -euo pipefail

ROOT=${0:A:h:h}
CACHE=${PIXIX_CACHE:-$HOME/Library/Caches/Pixix}
BUILD=$CACHE/build
APP=$CACHE/dist/Pixix.app
CONFIG=release
INSTALL=false
MAKE_DEFAULT=true
ZIP=false

for argument in "$@"; do
    case $argument in
        --install) INSTALL=true ;;
        --keep-defaults) MAKE_DEFAULT=false ;;
        --zip) ZIP=true ;;
        --debug) CONFIG=debug ;;
        *) echo "unknown option: $argument" >&2; exit 2 ;;
    esac
done

has_identity() {
    security find-identity -p codesigning 2>/dev/null | grep -q "\"$1\""
}

if [[ -n ${PIXIX_SIGN_IDENTITY:-} ]]; then
    IDENTITY=$PIXIX_SIGN_IDENTITY
    if [[ $IDENTITY != "-" ]] && ! has_identity "$IDENTITY"; then
        echo "Signing certificate \"$IDENTITY\" is not in the keychain." >&2
        exit 1
    fi
elif has_identity "Local Dev"; then
    IDENTITY="Local Dev"
else
    IDENTITY="-"
    echo "No signing certificate found; signing ad hoc."
    echo "With an ad hoc signature macOS asks for folder access again after every rebuild."
fi

swift build -c $CONFIG --package-path "$ROOT" --scratch-path "$BUILD" --product Pixix
BINARY=$(swift build -c $CONFIG --package-path "$ROOT" --scratch-path "$BUILD" --show-bin-path)/Pixix

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Pixix"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Files copied out of a cloud-synced folder carry attributes that codesign refuses.
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier me.fedorananin.pixix "$APP"
codesign --verify --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Built $APP (version $VERSION)"

if $ZIP; then
    rm -f "$CACHE/dist/Pixix.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$CACHE/dist/Pixix.zip"
    echo "Packed $CACHE/dist/Pixix.zip"
fi

if $INSTALL; then
    # Replace in place so the Dock and "Open With" keep pointing at the same app.
    rm -rf /Applications/Pixix.app
    ditto "$APP" /Applications/Pixix.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Pixix.app
    echo "Installed /Applications/Pixix.app"
    if $MAKE_DEFAULT; then
        # Claiming types needs no confirmation. The previous apps are remembered; "Pixix --restore-default"
        # or Settings hands them back, with one macOS confirmation dialog per file type.
        /Applications/Pixix.app/Contents/MacOS/Pixix --make-default
    fi
fi
