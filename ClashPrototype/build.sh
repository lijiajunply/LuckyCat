#!/bin/sh
set -eu

export GOTOOLCHAIN=local GOWORK=off GOFLAGS=-mod=readonly

prototype_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/luckycat-clash.XXXXXXXX")
echo "Clash prototype workspace: $work_dir"

sdk_tag=v1.19.34-clash.1
sdk_revision=c8f2fc1d58bf9ac856a0bf161bc9489591821f45
adapter_revision=9ba5c2724b68c753d57496c1036f4dfb1587e482
gomobile_version=v0.1.13

if [ "$(go env GOVERSION)" != go1.26.11 ]; then
    echo "Put the standalone Go 1.26.11 installation first in PATH." >&2
    exit 1
fi

git clone --quiet --depth 1 --branch "$sdk_tag" https://github.com/ProjectClash/Clash.git "$work_dir/core"
git init --quiet "$work_dir/adapter"
git -C "$work_dir/adapter" fetch --quiet --depth 1 https://github.com/ProjectClash/Clash-Adapter.git "$adapter_revision"
git -C "$work_dir/adapter" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$work_dir/core" rev-parse HEAD)" = "$sdk_revision"
test "$(git -C "$work_dir/adapter" rev-parse HEAD)" = "$adapter_revision"

(
    cd "$work_dir"
    shasum -a 256 -c "$prototype_dir/sources.sha256"
)

export GOBIN="$work_dir/bin"
go install "github.com/sagernet/gomobile/cmd/gomobile@$gomobile_version" "github.com/sagernet/gomobile/cmd/gobind@$gomobile_version"
export PATH="$GOBIN:$PATH"

framework="$work_dir/Clash.xcframework"
if ! (cd "$work_dir/core" && go run ./cmd/build_libbox -target apple -slices ios,macos -output "$framework") >"$work_dir/sdk-build.log" 2>&1; then
    tail -n 40 "$work_dir/sdk-build.log" >&2
    exit 1
fi

link_probe() {
    sdk=$1
    target=$2
    slice=$3
    library="$framework/$slice/Clash.framework/Clash"
    kind=$(xcrun --sdk "$sdk" lipo -archs "$library")
    case " $kind " in
        *" ${target%%-*} "*) ;;
        *) echo "Missing architecture $target in $library" >&2; exit 1 ;;
    esac
    xcrun --sdk "$sdk" swiftc -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -target "$target" -application-extension -F "$framework/$slice" \
        -framework Clash -lresolv "$work_dir/adapter"/Sources/ClashAdapter/*.swift \
        "$prototype_dir/SmokeProbe.swift" -o "$work_dir/probe-$target"
    echo "Linked $target against $slice ($kind)"
}

link_probe iphoneos arm64-apple-ios27.2 ios-arm64
link_probe iphonesimulator arm64-apple-ios27.2-simulator ios-arm64_x86_64-simulator
link_probe iphonesimulator x86_64-apple-ios27.2-simulator ios-arm64_x86_64-simulator
host_target="$(uname -m)-apple-macos15.0"
link_probe macosx "$host_target" macos-arm64_x86_64
"$work_dir/probe-$host_target"

(
    cd "$framework"
    shasum -a 256 Info.plist */Clash.framework/Clash
) >"$work_dir/sdk.sha256"
cat "$work_dir/sdk.sha256"

(
    cd "$work_dir/core/bind/clash"
    go test -tags with_gvisor,cmfa,with_quic,no_easytier -count=1 -v \
        -run '^(TestControlledWireGuardInterop|TestYAMLJSONBridgeOutputIsDeterministic|TestStartSurfacesPacketFlowBridgeDupFailure)$' .
)
