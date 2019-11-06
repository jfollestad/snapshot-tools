#!/bin/bashg

function local_cleanup() {
    umount_loop
    loop_cleanup
}

function setup_traps() {
    # local_cleanup at script exit
    trap local_cleanup ERR EXIT
}

function parse() {
    input="$1"
    output="$2"
}

function check_new_file() {
    #Copy to new file if requested
    if [ -n "$output" ]; then
        echo "Copying $input to $output..."
        cp --reflink=auto --sparse=always "$input" "$output"
        if (($? != 0)); then
            echo $LINENO "Could not copy file..."
            exit 1
        fi
        image="$output"
    else
        echo "changing in place"
        image="$input"
    fi
}

loop_setup() {
    p2_start_sector=$(sfdisk -J img/tmp.img | jq ".partitiontable.partitions[1].start")
    p2_start=$(($p2_start_sector * 512))
    echo "p2_start: $p2_start"

    loopback=$(sudo losetup -f --show -o "$p2_start" "$image")
    echo "Loopback: $loopback"

    #check filesystem
    sudo e2fsck -pf "$loopback"
}

loop_cleanup() {
    if losetup "$loopback" &>/dev/null; then
        sudo losetup -d "$loopback"
    fi
}

mount_loop() {
    sudo mount "$loopback" "$mountdir"
}

umount_loop() {
    if [ -n "$mountdir" ]; then
        sudo umount "$mountdir"
    fi
}

function gather_info() {
    p2_size=$(sudo blockdev --getsize64 "$loopback") && echo "p2 old size: $old_size"
    p2_block_size=$(sudo blockdev --getbsz "$loopback") && echo "p2_block_size: $p2_block_size"
    p2_size_sectors=$(sudo blockdev --getsz "$loopback") && echo "p2_size_sectors: $p2_size_sectors"30850049
    p2_minsize_string=$(sudo resize2fs -P "$loopback")
    p2_minsize_blocks=$(cut -d ':' -f 2 <<<"$p2_minsize_string" | tr -d ' ') && echo "p2_minsize_blocks: $p2_minsize_blocks"
    extra_space_blocks="32768" #128MB
    p2_new_size_blocks=$(($p2_minsize_blocks + $extra_space_blocks))
    p2_new_size_byte=$(($p2_new_size_blocks * $p2_block_size))
    p2_new_size_sectors=$(($p2_new_size_blocks * 8)) && echo "p2_new_size_blocks: $p2_new_size_blocks"
}

main() {
    #TRAAAAPS!
    setup_traps

    #INput
    parse "$@"

    #clean away old file
    #rm "$output"

    #make new copy?
    check_new_file

    # Create the loop device
    loop_setup

    #Gather all the info
    gather_info

    #resize the filesystem
    sudo resize2fs -p "$loopback" $p2_new_size_blocks

    loop_cleanup

    echo "start= $p2_start_sector, size= $p2_new_size_sectors" | sfdisk -N 2 img/tmp.img

    truncate -s $p2_new_size_byte img/tmp.img

    exit 0

    #Shrink partition
    partnewsize=$(($minsize * $blocksize))
    newpartend=$(($partstart + $partnewsize))
    echo $LINENO partnewsize newpartend
    if [ ! sudo parted -s -a minimal "$image" rm "$partnum" ]; then
        rc=$?
        echo $LINENO "parted failed with rc $rc"
        exit -13
    fi
    exit

    if ! sudo parted -s "$image" unit B mkpart primary "$partstart" "$newpartend"; then
        rc=$?
        echo $LINENO "parted failed with rc $rc"
        exit -14
    fi

    #Truncate the file
    info "Shrinking image"
    if ! endresult=$(parted -ms "$img" unit B print free); then
        rc=$?
        echo $LINENO "parted failed with rc $rc"
        exit -15
    fi

    endresult=$(tail -1 <<<"$endresult" | cut -d ':' -f 2 | tr -d 'B')
    logVariables $LINENO endresult
    if ! truncate -s "$endresult" "$image"; then
        rc=$?
        echo $LINENO "trunate failed with rc $rc"
        exit -16
    fi
}

# If this file is run directly and not sourced, run main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
30850049
