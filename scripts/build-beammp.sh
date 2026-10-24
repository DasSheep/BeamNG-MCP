#!/bin/sh
# Build one self-contained BeamMP resource; no Lua C modules or installed service.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
output=${1:?usage: build-beammp.sh output-directory [linux|windows] [amd64|arm64]}
target_os=${2:-linux}
target_arch=${3:-amd64}
case "$target_os/$target_arch" in linux/amd64|linux/arm64|windows/amd64|windows/arm64) ;; *) echo 'unsupported target' >&2; exit 1 ;; esac
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd)
dest="$output/$target_os-$target_arch/BeamMCP"
if [ -e "$dest/config.json" ] || [ -e "$dest/token" ] || [ -e "$dest/.runtime" ]; then
  echo 'Refusing to package a deployed resource directory; select a clean build output.' >&2
  exit 1
fi
mkdir -p "$dest/lib" "$dest/lua/common"
cp -R "$repo/beammp/BeamMCP/." "$dest/"
cp -R "$repo/lua/common/beammcp" "$dest/lua/common/"
cp "$repo/LICENSE" "$dest/LICENSE"
cp "$repo/beammp/examples/z_beammcp.lua" "$output/$target_os-$target_arch/z_beammcp.example.lua"
cd "$repo/beammp/helper"
go test ./...
name=beammcp-helper
flags='-s -w'
if [ "$target_os" = windows ]; then name=beammcp-helper.exe; flags="$flags -H windowsgui"; fi
CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" go build -trimpath -ldflags "$flags" -o "$dest/lib/$name" .
cat "$(go env GOROOT)/LICENSE" > "$dest/lib/Go-LICENSE.txt"
find "$(go env GOROOT)/src/vendor" -name LICENSE -type f -exec cat {} \; >> "$dest/lib/Go-LICENSE.txt"
revision=${BEAMMCP_REVISION:-unrecorded}
case "$revision" in *[!a-zA-Z0-9_-]*) echo 'invalid revision' >&2; exit 1 ;; esac
dirty=${BEAMMCP_DIRTY:-true}
case "$dirty" in true|false) ;; *) exit 1 ;; esac
cd "$dest"
digest=$(find . -type f ! -name build.json | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done | sha256sum | cut -d' ' -f1)
printf '{"schema":1,"sourceRevision":"%s","sourceDirty":%s,"contentSha256":"%s","os":"%s","arch":"%s"}\n' "$revision" "$dirty" "$digest" "$target_os" "$target_arch" > build.json
printf '%s\n' "$dest"
