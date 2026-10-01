#!/usr/bin/env bash
set -euo pipefail

targets=(
    "x86_64-windows:tfs-windows-x86_64.exe"
    "aarch64-windows:tfs-windows-arm64.exe"
    "x86_64-linux-musl:tfs-linux-x86_64"
    "aarch64-linux-musl:tfs-linux-arm64"
    "x86_64-macos:tfs-macos-x86_64"
    "aarch64-macos:tfs-macos-arm64"
)

mkdir -p dist

for item in "${targets[@]}"; do
    target="${item%%:*}"
    output="${item##*:}"

    echo "Building for ${target}..."
    zig build "-Dtarget=${target}" --release=fast

    if [[ "${target}" == *"windows"* ]]; then
        cp "zig-out/bin/tfs.exe" "dist/${output}"
    else
        cp "zig-out/bin/tfs" "dist/${output}"
    fi
done

echo "Done! Artifacts saved to ./dist/"
ls -lh dist/
