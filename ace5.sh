#!/bin/bash
set -e

# ── Logging ─────────────────────────────────────
info() { tput setaf 3; echo "[INFO] $1"; tput sgr0; }
error() { tput setaf 1; echo "[ERROR] $1"; tput sgr0; exit 1; }

# ── Device & manifest setup (Ace 5 only) ────────
DEVICE_NAME="oneplus_ace5"
REPO_MANIFEST="oneplus_ace5.xml"

# ── Feature toggles ─────────────────────────────
read -rp "Enable KPM? (Default: Y) [y/N]: " kpm
[[ "$kpm" =~ ^[Yy]$ ]] && ENABLE_KPM=true || ENABLE_KPM=false

read -rp "Enable LZ4+Zstd? (Default: Y) [y/N]: " lz4
[[ "$lz4" =~ ^[Yy]$ ]] && ENABLE_LZ4KD=true || ENABLE_LZ4KD=false

# ── ccache setup ────────────────────────────────
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR=1
export CCACHE_HARDLINK=1
export CCACHE_DIR="$HOME/.ccache_${DEVICE_NAME}"
export CCACHE_MAXSIZE="8G"

if command -v ccache &>/dev/null; then
  mkdir -p "$CCACHE_DIR"
  [ ! -f "$CCACHE_DIR/.ccache_initialized" ] && ccache -M "$CCACHE_MAXSIZE" && touch "$CCACHE_DIR/.ccache_initialized"
fi

# ── Workspace setup ─────────────────────────────
WORKSPACE="$HOME/kernel_${DEVICE_NAME}"
mkdir -p "$WORKSPACE" && cd "$WORKSPACE"

# ── Dependency check ────────────────────────────
DEPS=(python3 git curl ccache flex bison libssl-dev libelf-dev bc zip)
MISSING=()
for pkg in "${DEPS[@]}"; do dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg"); done
[ ${#MISSING[@]} -gt 0 ] && sudo apt update && sudo apt install -y "${MISSING[@]}"

# ── Git identity (placeholder) ──────────────────
git config --global user.name "anonymous"
git config --global user.email "anonymous@example.com"

# ── repo tool setup ─────────────────────────────
if ! command -v repo &>/dev/null; then
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o ~/repo
  chmod +x ~/repo && sudo mv ~/repo /usr/local/bin/repo
fi

# ── Source init ─────────────────────────────────
KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"
mkdir -p "$KERNEL_WORKSPACE" && cd "$KERNEL_WORKSPACE"

repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1
repo sync -c -j"$(nproc)" --no-tags

# ── Clean dirty flags ───────────────────────────
for d in kernel_platform/common kernel_platform/msm-kernel; do
  rm "$d"/android/abi_gki_protected_exports_* 2>/dev/null || true
done
sed -i 's/ -dirty//g' kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion

# ── Auto-detect kernel version and inject suffix ─
cd kernel_platform/common
VERSION=$(grep '^VERSION =' Makefile | awk '{print $3}')
PATCHLEVEL=$(grep '^PATCHLEVEL =' Makefile | awk '{print $3}')
SUBLEVEL=$(grep '^SUBLEVEL =' Makefile | awk '{print $3}')
KERNEL_VERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}+@hipuu"

cd arch/arm64/configs
DEFCONFIG="gki_defconfig"
echo "CONFIG_LOCALVERSION=\"${KERNEL_VERSION}\"" >> "$DEFCONFIG"
[ "$ENABLE_KPM" = true ] && echo "CONFIG_KPM=y" >> "$DEFCONFIG"
cd ../../../..

# ── SukiSU & patch setup ────────────────────────
cd kernel_platform
curl -LSs https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh | bash -s susfs-main

cd KernelSU
KSU_VERSION=$(( $(git rev-list --count main) + 10700 ))
export KSU_VERSION
sed -i "s/DKSU_VERSION=.*/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile

cd "$KERNEL_WORKSPACE"
git clone -b gki-android14-6.1 https://gitlab.com/simonpunk/susfs4ksu.git || true
git clone https://github.com/Xiaomichael/kernel_patches.git || true
git clone -q https://github.com/SukiSU-Ultra/SukiSU_patch.git || true

cd kernel_platform/common
cp ../../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./
cp ../../kernel_patches/next/syscall_hooks.patch ./
patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
patch -p1 -F3 < syscall_hooks.patch

if [ "$ENABLE_LZ4KD" = true ]; then
  cp ../../kernel_patches/001-lz4.patch ./
  cp ../../kernel_patches/002-zstd.patch ./
  git apply -p1 < 001-lz4.patch || true
  patch -p1 < 002-zstd.patch || true
  cp ../../kernel_patches/lz4armv8.S ./lib/
fi

# ── Build ───────────────────────────────────────
export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

cd "$KERNEL_WORKSPACE/kernel_platform/common"
make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" O=out gki_defconfig
make -j"$(nproc)" LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" O=out Image

if [ "$ENABLE_KPM" = true ]; then
  cd out/arch/arm64/boot
  curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
  chmod +x patch_linux && ./patch_linux
  mv oImage Image
fi

# ── Package ─────────────────────────────────────
cd "$WORKSPACE"
git clone -q https://github.com/showdo/AnyKernel3.git --depth=1 || true
rm -rf AnyKernel3/.git AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" AnyKernel3/
cd AnyKernel3
zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" ./*

# ── Export to Windows ───────────────────────────
WIN_OUTPUT="/mnt/c/Kernel_Build/${DEVICE_NAME}"
mkdir -p "$WIN_OUTPUT"
cp Image "$WIN_OUTPUT/"
cp "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" "$WIN_OUTPUT/"

info "Build complete. Output copied to C:/Kernel_Build/${DEVICE_NAME}/"

# ── Optional cleanup ────────────────────────────
read -rp "Remove build workspace? [y/N]: " cleanup
[[ "$cleanup" =~ ^[Yy]$ ]] && sudo rm -rf "$WORKSPACE" && info "Workspace removed."
