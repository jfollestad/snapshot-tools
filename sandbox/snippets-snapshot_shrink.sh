#!/bin/bash

blockdev --getbsz partition

parted

mkdir /mnt/ChromeOS
mount -o loop image.img /mnt/ChromeOS/

# Clear empty space
dd if=/dev/zero of=bigfile bs=1M