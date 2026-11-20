#!/bin/sh
set -eu

# Stages the pinned Clash.xcframework slice that matches the current build.
# The binary is not committed; build it with ./ClashPrototype/build.sh or place
# a Clash.xcframework under Frameworks/ first.

framework="$SRCROOT/Frameworks/Clash.xcframework"
if [ ! -d "$framework" ]; then
    echo "Missing $framework. Run ClashPrototype/build.sh or copy a prebuilt Clash.xcframework into Frameworks/." >&2
    exit 1
fi

slice="$PLATFORM_NAME"
if [ "$slice" = "iphonesimulator" ]; then
    slice="ios-arm64_x86_64-simulator"
elif [ "$slice" = "iphoneos" ]; then
    slice="ios-arm64"
else
    slice="macos-arm64_x86_64"
fi

source="$framework/$slice/Clash.framework"
if [ ! -d "$source" ]; then
    echo "Missing $source" >&2
    exit 1
fi

destination="$DERIVED_FILE_DIR/Clash.framework"
rm -rf "$destination"
mkdir -p "$DERIVED_FILE_DIR"
cp -R "$source" "$destination"
