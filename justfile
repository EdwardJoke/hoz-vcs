default: ci

version := "v0.3.0"

# ── CI Pipeline (local equivalent of GitHub Actions) ──

ci: build test lint

build:
    zig build

test:
    zig build test

lint:
    zig fmt --check .

# ── Cross-Platform Release Builds ──

clean-cache:
    rm -rf zig-out

macos-aarch64:
    zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
    mkdir -p assets
    cp zig-out/bin/hoz assets/hoz-{{version}}-macos-aarch64

macos-x86_64:
    zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe
    mkdir -p assets
    cp zig-out/bin/hoz assets/hoz-{{version}}-macos-x86_64

linux-x86_64:
    zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
    mkdir -p assets
    upx -9 -q -o zig-out/bin/hoz-compressed zig-out/bin/hoz
    cp zig-out/bin/hoz-compressed assets/hoz-{{version}}-linux-x86_64

linux-aarch64:
    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
    mkdir -p assets
    upx -9 -q -o zig-out/bin/hoz-compressed zig-out/bin/hoz
    cp zig-out/bin/hoz-compressed assets/hoz-{{version}}-linux-aarch64

windows-x86_64:
    zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
    mkdir -p assets
    upx -9 -q -o zig-out/bin/hoz-compressed.exe zig-out/bin/hoz.exe
    cp zig-out/bin/hoz-compressed.exe assets/hoz-{{version}}-windows-x86_64.exe

# ── Release Packaging ──

assets: macos-aarch64 macos-x86_64 linux-x86_64 clean-cache linux-aarch64 clean-cache windows-x86_64

release: clean assets
    cd assets && tar czf hoz-{{version}}-macos-aarch64.tar.gz hoz-{{version}}-macos-aarch64
    cd assets && tar czf hoz-{{version}}-macos-x86_64.tar.gz hoz-{{version}}-macos-x86_64
    cd assets && tar czf hoz-{{version}}-linux-x86_64.tar.gz hoz-{{version}}-linux-x86_64
    cd assets && tar czf hoz-{{version}}-linux-aarch64.tar.gz hoz-{{version}}-linux-aarch64
    cd assets && zip hoz-{{version}}-windows-x86_64.zip hoz-{{version}}-windows-x86_64.exe

clean:
    rm -rf assets zig-out

