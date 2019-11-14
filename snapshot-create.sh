#!/bin/bash

input=$1
output=$2

disksize=$(sudo blockdev --getsize64 $input)
echo "Disc size is: $disksize"

blocksize=$(sudo blockdev --getbsz $input)
echo "Blocksize on input is: $blocksize"

sudo dd bs=$blocksize if=$input | pv -s $disksize | dd of=$output
#sudo dd bs=4096 if=$input | pv -s $disksize | sudo gzip -9 > $output
#sudo dd if=$input of=$output status=progress

sudo chown $USER:$USER $output
