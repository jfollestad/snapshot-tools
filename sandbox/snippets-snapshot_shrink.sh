#!/bin/bash

blockdev --getbsz partition

parted

mkdir /mnt/ChromeOS
mount -o loop image.img /mnt/ChromeOS/

# Clear empty space
dd if=/dev/zero of=bigfile bs=1M



	#part_dump=$(mktemp)
	#sfdisk -d $dev > $part_dump
	#p2_finish_current=$(cat $part_dump | tail -1 | awk '{print $6}' | tr -d ',')
	#sed -i "s/$p2_finish_current/$p2_finish/g" $part_dump

sudo sfdisk -s /dev/mmcblk1
