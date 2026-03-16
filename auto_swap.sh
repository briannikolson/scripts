#!/usr/bin/env bash

set -e

SWAPFILE="/swapfile"

echo "Detecting RAM..."

RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

echo "RAM: ${RAM_MB} MB"

# enterprise логика расчета swap
if (( RAM_MB <= 2048 )); then
    TARGET_SWAP_MB=$((RAM_MB * 2))
elif (( RAM_MB <= 8192 )); then
    TARGET_SWAP_MB=$RAM_MB
elif (( RAM_MB <= 65536 )); then
    TARGET_SWAP_MB=$((RAM_MB / 2))
else
    TARGET_SWAP_MB=8192
fi

echo "Calculated swap: ${TARGET_SWAP_MB} MB"

CURRENT_SWAP_MB=$(swapon --show --bytes --noheadings 2>/dev/null | awk '{sum+=$3} END {printf "%d", sum/1024/1024}')
[ -z "$CURRENT_SWAP_MB" ] && CURRENT_SWAP_MB=0

echo "Current swap: ${CURRENT_SWAP_MB} MB"

if (( CURRENT_SWAP_MB >= TARGET_SWAP_MB )); then
    echo "Swap already sufficient"
    swapon --show
    exit 0
fi

echo "Configuring swap..."

# если swapfile уже есть — расширяем
if [ -f "$SWAPFILE" ]; then

    echo "Existing swapfile found"

    swapoff "$SWAPFILE" 2>/dev/null || true

    CURRENT_FILE_MB=$(du -m "$SWAPFILE" | awk '{print $1}')

    if (( CURRENT_FILE_MB < TARGET_SWAP_MB )); then
        echo "Expanding swapfile from ${CURRENT_FILE_MB}MB to ${TARGET_SWAP_MB}MB"
        fallocate -l ${TARGET_SWAP_MB}M "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$TARGET_SWAP_MB
    fi

else

    echo "Creating swapfile ${TARGET_SWAP_MB}MB"

    fallocate -l ${TARGET_SWAP_MB}M "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$TARGET_SWAP_MB

fi

chmod 600 "$SWAPFILE"

mkswap "$SWAPFILE"

swapon "$SWAPFILE"

# fstab
if ! grep -q "$SWAPFILE" /etc/fstab; then
    echo "$SWAPFILE swap swap defaults 0 0" >> /etc/fstab
fi

# kernel tuning
sysctl -w vm.swappiness=10 >/dev/null
sysctl -w vm.vfs_cache_pressure=50 >/dev/null

grep -q vm.swappiness /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
grep -q vm.vfs_cache_pressure /etc/sysctl.conf || echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf

echo
echo "Swap configured successfully"
swapon --show
free -h
