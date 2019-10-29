#!/bin/bash

inputfile=$1
outputfile=$2

disksize=$(sudo blockdev --getsize64 $inputfile)
echo "Disc size is: $disksize"

#usedsize=$(sudo du -sb $inputfile | awk '{print $1}')
#echo "Used size is: ${usedsize}B"

#sudo dd if=$inputfile | pv -s $disksize | dd of=$outputfile
#sudo dd bs=4096 if=$inputfile | pv -s $disksize | sudo gzip -9 > $outputfile

sudo dd if=$inputfile of=$outputfile status=progress

sudo chown $USER:$USER $outputfile