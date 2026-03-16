#!/bin/bash

set -e

SWAPFILE="/swapfile"

echo "Detecting RAM..."

RAM_MB=$(free -m | awk '/Mem:/ {print $2}')

echo "RAM: ${RAM_MB} MB"

# расчет swap
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

CURRENT_SWAP_MB=$(swapon --show --bytes --noheadings | awk '{sum+=$3} END {print sum/1024/1024}')
CURRENT_SWAP_MB=${CURRENT_SWAP_MB:-0}

echo "Current swap: ${CURRENT_SWAP_MB} MB"

if (( CURRENT_SWAP_MB >= TARGET_SWAP_MB )); then
    echo "Swap already sufficient."
    swapon --show
    exit 0
fi

echo "Reconfiguring swap..."

if swapon --show | grep -q "$SWAPFILE"; then
    swapoff $SWAPFILE
fi

rm -f $SWAPFILE

echo "Creating swapfile..."

fallocate -l ${TARGET_SWAP_MB}M $SWAPFILE 2>/dev/null || dd if=/dev/zero of=$SWAPFILE bs=1M count=$TARGET_SWAP_MB

chmod 600 $SWAPFILE
mkswap $SWAPFILE
swapon $SWAPFILE

grep -v "$SWAPFILE" /etc/fstab > /tmp/fstab.tmp
mv /tmp/fstab.tmp /etc/fstab

echo "$SWAPFILE swap swap defaults 0 0" >> /etc/fstab

sysctl vm.swappiness=10
sysctl vm.vfs_cache_pressure=50

grep -q vm.swappiness /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
grep -q vm.vfs_cache_pressure /etc/sysctl.conf || echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf

echo
echo "Swap configured successfully:"
swapon --show
free -h
