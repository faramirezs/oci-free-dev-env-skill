#!/usr/bin/env bash
# Storage: root filesystem usage, and the partition spanning the boot volume.
set -u

used="$(df / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
if [ "${used:-100}" -gt 80 ]; then
    echo "root filesystem is ${used}% full (threshold 80%)"
    exit 1
fi
echo "root filesystem: ${used}% used"

part="$(findmnt -no SOURCE /)"
disk="/dev/$(lsblk -no PKNAME "$part" | head -1)"
if [ ! -b "$disk" ]; then
    echo "could not resolve the block device behind $part"
    exit 1
fi

part_bytes="$(lsblk -bndo SIZE "$part")"
disk_bytes="$(lsblk -bndo SIZE "$disk")"
if [ "$part_bytes" -lt $((disk_bytes * 99 / 100)) ]; then
    echo "$part ($part_bytes bytes) does not span $disk ($disk_bytes bytes)"
    echo "grow it: growpart $disk ${part##*[!0-9]} && resize2fs $part"
    exit 1
fi
echo "partition spans the volume: $(lsblk -no SIZE "$part") of $(lsblk -no SIZE "$disk")"

echo "storage OK"
