#!/usr/bin/env bash
#
# Cross-compile Stockfish for a Kobo, and install it as a Kobo Chess engine.
#
#   tools/build_stockfish.sh              build for the device (armv7)
#   tools/build_stockfish.sh --native     build for this machine, to test in
#                                         the emulator
#
# The result lands in kobochess.koplugin/engines/stockfish/, which install.sh
# then copies to the device like anything else in the plugin.
#
# Nothing here needs root. The ARM toolchain is a self-contained tarball from
# toolchains.bootlin.com, downloaded into local/ on first use.
#
# Three decisions worth knowing about:
#
# *Static, against musl.* A Kobo runs an old glibc, and a binary linked
# against a newer one will not start. Linking everything in means the engine
# depends on nothing the device provides.
#
# *The network is a separate file, not built into the binary.* Stockfish
# normally embeds its evaluation network, which would make a 110 MB
# executable. Kept beside it instead, the binary is a couple of megabytes and
# the network can be replaced without rebuilding.
#
# *A patch.* Stockfish's 32-bit ARM NEON path does not compile: a helper that
# stands in for an instruction 32-bit ARM lacks is declared returning the
# wrong vector type. One line, in tools/stockfish-armv7-neon.patch.

set -euo pipefail

# The release to build. Pinned rather than tracking master, so that what is
# tested is what gets installed.
SF_TAG="${SF_TAG:-sf_18}"

TOOLCHAIN_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs/armv7-eabihf--musl--stable-2025.08-1.tar.xz"
TOOLCHAIN_DIR_NAME="armv7-eabihf--musl--stable-2025.08-1"

cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$ROOT/local/stockfish"
DEST="$ROOT/kobochess.koplugin/engines/stockfish"

NATIVE=0
[[ "${1:-}" == "--native" ]] && NATIVE=1

for tool in git make curl tar; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

mkdir -p "$WORK"

# --- source ----------------------------------------------------------------
if [[ ! -d "$WORK/src/.git" ]]; then
    echo "Fetching Stockfish…"
    git clone --quiet https://github.com/official-stockfish/Stockfish.git "$WORK/src"
fi
git -C "$WORK/src" fetch --quiet --tags
git -C "$WORK/src" checkout --quiet "$SF_TAG"
echo "Stockfish $SF_TAG"

# --- native build, for testing in the emulator -----------------------------
if [[ $NATIVE -eq 1 ]]; then
    echo "Building for this machine…"
    make -C "$WORK/src/src" -j"$(nproc)" build ARCH=native >/dev/null
    mkdir -p "$DEST"
    cp "$WORK/src/src/stockfish" "$DEST/engine"
    echo "Installed $DEST/engine (native, network embedded)"
    exit 0
fi

# --- toolchain -------------------------------------------------------------
TC="$ROOT/local/toolchain/$TOOLCHAIN_DIR_NAME"
if [[ ! -x "$TC/bin/arm-linux-g++" ]]; then
    echo "Fetching the ARM toolchain (about 75 MB)…"
    mkdir -p "$ROOT/local/toolchain"
    curl -sL -o "$ROOT/local/toolchain/tc.tar.xz" "$TOOLCHAIN_URL"
    tar xf "$ROOT/local/toolchain/tc.tar.xz" -C "$ROOT/local/toolchain"
    rm -f "$ROOT/local/toolchain/tc.tar.xz"
fi

# --- patched copy of the tree ----------------------------------------------
# Built in a copy so the pristine checkout stays pristine, and so a native
# build and a cross build can coexist without fighting over object files.
rm -rf "$WORK/arm"
cp -r "$WORK/src" "$WORK/arm"

if patch -d "$WORK/arm" -p1 --forward --silent < "$ROOT/tools/stockfish-armv7-neon.patch"; then
    echo "Applied the armv7 NEON fix."
else
    # Already fixed upstream is a success, not a failure; anything else is not.
    if grep -q "int16x8_t vmovl_high_s8" "$WORK/arm/src/nnue/simd.h"; then
        echo "The armv7 NEON fix is already present upstream; carrying on."
    else
        echo "error: tools/stockfish-armv7-neon.patch did not apply to $SF_TAG." >&2
        echo "       Check whether it is still needed before removing it." >&2
        exit 1
    fi
fi

# --- build -----------------------------------------------------------------
echo "Cross-compiling for armv7…"
make -C "$WORK/arm/src" -j"$(nproc)" build \
    ARCH=armv7-neon COMP=gcc \
    CXX="$TC/bin/arm-linux-g++" \
    EXTRACXXFLAGS="-DNNUE_EMBEDDING_OFF" \
    EXTRALDFLAGS="-static" >/dev/null

"$TC/bin/arm-linux-strip" "$WORK/arm/src/stockfish"

# --- install ---------------------------------------------------------------
# The network is whatever the source tree says it wants; the Makefile will
# have downloaded it during the build.
NET=$(grep -o 'nn-[0-9a-f]*\.nnue' "$WORK/arm/src/evaluate.h" | head -1)
if [[ ! -f "$WORK/arm/src/$NET" ]]; then
    echo "error: $NET was not downloaded; run make net in $WORK/arm/src" >&2
    exit 1
fi

mkdir -p "$DEST"
cp "$WORK/arm/src/stockfish" "$DEST/engine"
cp "$WORK/arm/src/$NET" "$DEST/$NET"
chmod +x "$DEST/engine"

echo
echo "Installed:"
ls -la "$DEST"
file "$DEST/engine" 2>/dev/null || true
echo
echo "Now run ./install.sh <target> to copy it to the device."
