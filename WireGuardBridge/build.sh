#!/bin/sh
set -eu

# Xcode's build environment does not inherit the interactive shell's Go path.
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
export GOTOOLCHAIN=go1.26.1
export GOOS=ios CGO_ENABLED=1
export CC
CC="$(xcrun --sdk "$SDK_NAME" --find clang)"

case "$PLATFORM_NAME" in
    iphoneos) target_suffix="" ;;
    iphonesimulator) target_suffix="-simulator" ;;
    *) echo "error: Unsupported WireGuard build platform: $PLATFORM_NAME" >&2; exit 1 ;;
esac

cd "$SRCROOT/WireGuardBridge"
mkdir -p "$DERIVED_FILE_DIR"

for architecture in $ARCHS; do
    case "$architecture" in
        arm64) export GOARCH=arm64 ;;
        x86_64) export GOARCH=amd64 ;;
        *) echo "error: Unsupported WireGuard architecture: $architecture" >&2; exit 1 ;;
    esac

    target="$architecture-apple-ios$IPHONEOS_DEPLOYMENT_TARGET$target_suffix"
    export CGO_CFLAGS="-target $target -isysroot $SDKROOT"
    export CGO_LDFLAGS="$CGO_CFLAGS"
    archive="$DERIVED_FILE_DIR/libLuckyClashWireGuard-$architecture.a"
    go build -mod=readonly -trimpath -buildmode=c-archive -o "$archive" .
    set -- "$@" "$archive"
done

xcrun lipo -create "$@" -output "$SCRIPT_OUTPUT_FILE_0"
