#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CAAS Celadon Installer Image Builder
# Installed in vendor/intel/utils_vertical/tools.
# Run from a terminal in a Celadon checkout.
# ============================================================

# ------------------------------------------------------------
# 自动确定 Celadon 源码根目录
# 不使用 $PWD，因为双击脚本时当前目录可能不是源码根目录
# ------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
cd "$TOP"

PRODUCT="$TOP/out/target/product/caas"
if [ "$#" -gt 1 ]; then
    echo "用法: $0 [flashfiles.zip]" >&2
    exit 2
fi

# A user build has a different flashfiles name. Keep the existing default and
# allow an explicit archive for other build variants.
ZIP="${1:-$PRODUCT/caas-flashfiles-userdebug-cyanogen.zip}"
WORK="$PRODUCT/installer-media-work"
ROOT="$WORK/root"
IMG="$PRODUCT/caas-installer.img"

SHELL_EFI="$TOP/device/linaro/bootloader/edk2/EdkShellBinPkg/FullShell/X64/Shell_Full.efi"

echo "============================================================"
echo " CAAS Celadon Installer Image Builder"
echo "============================================================"
echo
echo "Celadon root:"
echo "  $TOP"
echo
echo "Flashfiles:"
echo "  $ZIP"
echo
echo "Output image:"
echo "  $IMG"
echo

# ------------------------------------------------------------
# 检查依赖程序
# ------------------------------------------------------------
for cmd in unzip truncate parted losetup udevadm mkfs.vfat mountpoint awk grep find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] 缺少必要命令：$cmd"
        echo
        exit 1
    fi
done

# ------------------------------------------------------------
# 检查输入文件
# ------------------------------------------------------------
if [ ! -f "$ZIP" ]; then
    echo "[ERROR] 找不到 flashfiles ZIP："
    echo "  $ZIP"
    echo
    echo "请先完成 nmb271 flashfiles 编译。"
    exit 1
fi

if [ ! -f "$SHELL_EFI" ]; then
    echo "[ERROR] 找不到 EFI Shell："
    echo "  $SHELL_EFI"
    echo
    exit 1
fi

echo "[OK] flashfiles ZIP"
echo "[OK] EFI Shell"
echo

# ------------------------------------------------------------
# 清理上一次生成结果
# ------------------------------------------------------------
echo "清理旧的工作目录..."

rm -rf "$WORK"
rm -f "$IMG"

mkdir -p "$ROOT"

# ------------------------------------------------------------
# 解压 flashfiles
# ------------------------------------------------------------
echo "解压 flashfiles..."

unzip -q "$ZIP" -d "$ROOT"

echo
echo "检查安装器文件："

REQUIRED_FILES=(
    installer.efi
    installer.cmd
    startup.nsh
    gpt.bin
    boot.img
    vendor_boot.img
    super.img
)

for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$ROOT/$f" ]; then
        echo "[MISSING] $ROOT/$f"
        exit 1
    fi

    echo "[OK] $f"
done

# ------------------------------------------------------------
# FAT32 单文件 4 GiB 限制
# ------------------------------------------------------------
echo
echo "检查 FAT32 单文件大小限制..."

LARGE_FILE="$(
    find "$ROOT" -type f -size +4095M -print -quit
)"

if [ -n "$LARGE_FILE" ]; then
    echo "[ERROR] 存在超过 FAT32 4 GiB 限制的文件："
    find "$ROOT" -type f -size +4095M -print
    echo
    exit 1
fi

echo "[OK] 没有超过 4 GiB 的单文件"

# ------------------------------------------------------------
# 计算镜像尺寸
# 文件总大小 + 768 MiB
# 再向上取整到完整 GiB
# ------------------------------------------------------------
PAYLOAD_BYTES="$(du -sb "$ROOT" | awk '{print $1}')"

GIB=$((1024 * 1024 * 1024))
MARGIN=$((768 * 1024 * 1024))

IMAGE_BYTES=$((PAYLOAD_BYTES + MARGIN))
IMAGE_BYTES=$((((IMAGE_BYTES + GIB - 1) / GIB) * GIB))

echo
echo "Payload bytes : $PAYLOAD_BYTES"
echo "Image bytes   : $IMAGE_BYTES"
echo "Image size    : $((IMAGE_BYTES / GIB)) GiB"
echo

# ------------------------------------------------------------
# 创建空 IMG
# ------------------------------------------------------------
echo "创建磁盘镜像..."

truncate -s "$IMAGE_BYTES" "$IMG"

# ------------------------------------------------------------
# 创建 GPT + ESP
# ------------------------------------------------------------
echo "创建 GPT 分区表..."

parted -s "$IMG" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 100% \
    set 1 esp on

LOOP=""
MNT=""

# ------------------------------------------------------------
# 清理函数
# 无论成功还是失败都尽量卸载 loop/mount
# ------------------------------------------------------------
cleanup()
{
    local status=$?

    set +e

    if [ -n "${MNT:-}" ] && mountpoint -q "$MNT"; then
        echo
        echo "卸载安装镜像..."
        sudo umount "$MNT"
    fi

    if [ -n "${LOOP:-}" ]; then
        sudo losetup -d "$LOOP" 2>/dev/null || true
    fi

    if [ -n "${MNT:-}" ] && [ -d "$MNT" ]; then
        rmdir "$MNT" 2>/dev/null || true
    fi

    exit "$status"
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# 建立 loop device
# ------------------------------------------------------------
echo "建立 loop device..."

LOOP="$(sudo losetup --find --show --partscan "$IMG")"

echo "Loop device:"
echo "  $LOOP"

sudo udevadm settle

PART="${LOOP}p1"

if [ ! -b "$PART" ]; then
    echo "[ERROR] 没有生成分区设备："
    echo "  $PART"
    exit 1
fi

echo "[OK] $PART"

# ------------------------------------------------------------
# FAT32 格式化
# ------------------------------------------------------------
echo
echo "格式化 ESP..."

sudo mkfs.vfat -F 32 -n NMB271INST "$PART"

# ------------------------------------------------------------
# 挂载
# ------------------------------------------------------------
MNT="$(mktemp -d)"

echo
echo "挂载到："
echo "  $MNT"

sudo mount "$PART" "$MNT"

# ------------------------------------------------------------
# 复制 Celadon flashfiles
# ------------------------------------------------------------
echo
echo "复制 flashfiles..."

sudo cp -r "$ROOT"/. "$MNT"/

# ------------------------------------------------------------
# 创建标准 UEFI removable-media 启动路径
# ------------------------------------------------------------
echo "安装 UEFI Shell..."

sudo mkdir -p "$MNT/EFI/BOOT"

sudo cp \
    "$SHELL_EFI" \
    "$MNT/EFI/BOOT/BOOTX64.EFI"

# ------------------------------------------------------------
# EFI Shell 备用 startup.nsh
# ------------------------------------------------------------
sudo tee "$MNT/EFI/BOOT/startup.nsh" >/dev/null <<'EOF'
cd \
installer.efi --batch installer.cmd
EOF

sync

# ------------------------------------------------------------
# 最终验证
# ------------------------------------------------------------
echo
echo "安装介质关键文件："

sudo find "$MNT" -maxdepth 3 -type f \
    \( -iname 'bootx64.efi' \
       -o -iname 'startup.nsh' \
       -o -iname 'installer.efi' \
       -o -iname 'installer.cmd' \) \
    -printf '%P\n' |
sort

echo
echo "============================================================"
echo " Installer image created successfully"
echo "============================================================"
echo
echo "输出文件："
echo "  $IMG"
echo
echo "镜像大小："
du -h "$IMG"
echo
