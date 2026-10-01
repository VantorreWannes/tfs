$ErrorActionPreference = "Stop"

$targets = @(
    @{ Target = "x86_64-windows";     Output = "tfs-windows-x86_64.exe" },
    @{ Target = "aarch64-windows";    Output = "tfs-windows-arm64.exe" },
    @{ Target = "x86_64-linux-musl";  Output = "tfs-linux-x86_64" },
    @{ Target = "aarch64-linux-musl"; Output = "tfs-linux-arm64" },
    @{ Target = "x86_64-macos";       Output = "tfs-macos-x86_64" },
    @{ Target = "aarch64-macos";      Output = "tfs-macos-arm64" }
)

New-Item -ItemType Directory -Force -Path "dist" | Out-Null

foreach ($t in $targets)
{
    Write-Host "Building for $($t.Target)..." -ForegroundColor Cyan
    $targetFlag = "-Dtarget=$($t.Target)"
    zig build $targetFlag --release=fast

    $bin = if ($t.Target -like "*windows*")
    { "zig-out/bin/tfs.exe"
    } else
    { "zig-out/bin/tfs"
    }
    Copy-Item $bin -Destination "dist/$($t.Output)" -Force
}

Write-Host "Done! Artifacts saved to ./dist/" -ForegroundColor Green
Get-ChildItem dist/
