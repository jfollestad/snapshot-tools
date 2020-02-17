



if ! minsize=$(resize2fs -P "$loopback"); then
  rc=$?
  error $LINENO "resize2fs failed with rc $rc"
  exit -10
fi
minsize=$(cut -d ':' -f 2 <<<"$minsize" | tr -d ' ')
logVariables $LINENO minsize
if [[ $currentsize -eq $minsize ]]; then
  error $LINENO "Image already shrunk to smallest size"
  exit -11
fi

#Add some free space to the end of the filesystem
extra_space=$(($currentsize - $minsize))
logVariables $LINENO extra_space
for space in 5000 1000 100; do
  if [[ $extra_space -gt $space ]]; then
    minsize=$(($minsize + $space))
    break
  fi
done
logVariables $LINENO minsize

#Shrink filesystem
info "Shrinking filesystem"
resize2fs -p "$loopback" $minsize
if [[ $? != 0 ]]; then
  error $LINENO "resize2fs failed"
  mount "$loopback" "$mountdir"
  mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
  umount "$mountdir"
  losetup -d "$loopback"
  exit -12
fi
sleep 1

#Shrink partition
partnewsize=$(($minsize * $blocksize))
newpartend=$(($partstart + $partnewsize))
logVariables $LINENO partnewsize newpartend
if ! parted -s -a minimal "$img" rm "$partnum"; then
  rc=$?
  error $LINENO "parted failed with rc $rc"
  exit -13
fi

if ! parted -s "$img" unit B mkpart primary "$partstart" "$newpartend"; then
  rc=$?
  error $LINENO "parted failed with rc $rc"
  exit -14
fi

#Truncate the file
info "Shrinking image"
if ! endresult=$(parted -ms "$img" unit B print free); then
  rc=$?
  error $LINENO "parted failed with rc $rc"
  exit -15
fi

endresult=$(tail -1 <<<"$endresult" | cut -d ':' -f 2 | tr -d 'B')
logVariables $LINENO endresult
if ! truncate -s "$endresult" "$img"; then
  rc=$?
  error $LINENO "trunate failed with rc $rc"
  exit -16
fi

if [[ $gzip_compress == true ]]; then
  info "Gzipping the shrunk image"
  if [[ ! $(gzip -f9 "$img") ]]; then
    img=$img.gz
  fi
fi

aftersize=$(ls -lh "$img" | cut -d ' ' -f 5)
logVariables $LINENO aftersize

info "Shrunk $img from $beforesize to $aftersize"
