#!/bin/bashg

function local_cleanup() {
    loop_umount
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

function gather_pre_loop_info() {
    echo ""
}

function loop_setup() {
    p2_start_sector=$(sfdisk -J $image | jq ".partitiontable.partitions[1].start")
    echo "p2_start_sector: $p2_start_sector"

    p2_start=$(($p2_start_sector * 512))
    echo "p2_start: $p2_start"

    #Create loop
    loopdevice=$(sudo losetup -f --show -o "$p2_start" "$image")
    echo "loopdevice: $loopdevice"

    #check filesystem
    sudo e2fsck -pf "$loopdevice"
    echo "e2fsck: $?" #If not catched, this causes an error later. Unknown why.
}

function loop_cleanup() {
    if losetup "$loopdevice" &>/dev/null; then
        sudo losetup -d "$loopdevice"
    fi
}

function loop_mount() {
    mountdir=$(mktemp -d)
    sudo mount "$loopdevice" "$mountdir"
}

function loop_umount() {
    if [ -n "$mountdir" ]; then
        sudo umount "$mountdir"
        mountdir=""
    fi
}

function gather_info() {
    p2_size=$(sudo blockdev --getsize64 "$loopdevice")
    echo "p2_size: $p2_size"

    p2_block_size=$(sudo blockdev --getbsz "$loopdevice")
    echo "p2_block_size: $p2_block_size"

    p2_size_sectors=$(sudo blockdev --getsz "$loopdevice")
    echo "p2_size_sectors: $p2_size_sectors"

    p2_minsize_blocks=$(sudo resize2fs -P "$loopdevice" | awk '{print $NF}')
    echo "p2_minsize_blocks: $p2_minsize_blocks"

    extra_space_blocks=$((134217728 / $p2_block_size)) # 128MB / blocksize
    echo "extra_space_blocks: $extra_space_blocks"

    p2_new_size_blocks=$(($p2_minsize_blocks + $extra_space_blocks))
    echo "p2_new_size_blocks: $p2_new_size_blocks"

    p2_new_size_sectors=$(($p2_new_size_blocks * 8)) && echo "p2_new_size_blocks: $p2_new_size_blocks"
    echo "p2_new_size_sectors: $p2_new_size_sectors"

    part_new_size_sectors=$(( $p2_start_sector + $p2_new_size_sectors))

    part_new_size_byte=$(($part_new_size_sectors * 512 ))
    echo "part_new_size_byte: $part_new_size_byte"
}

function clear_free_space() {
    echo "Zeroing space..."
    dd if=/dev/zero of=$mountdir/home/odroid/null.file bs=512
    ls -lh $mountdir/home/odroid
    rm $mountdir/home/odroid/null.file
    ls -lh $mountdir/home/odroid
    echo "... and done zeroing space."
}

function insert_autoresize_files() {
    scriptpath=$(dirname $(realpath $0))
    sudo touch $mountdir/.firstboot
    sudo cp $scriptpath/src/aafirstboot $mountdir/
}

function main() {
    #TRAAAAPS!
    setup_traps

    #Input
    parse "$@"

    #clean away old file
    if [ -n "$output" ]; then
        echo "Removing old outputfile..."
        rm "$output"
        echo "...gone."
    fi

    #make new copy?
    check_new_file

    # Gather pre loop info
    gather_pre_loop_info

    # Create the loop device
    loop_setup

    #Gather all the info
    gather_info

    #resize the filesystem
    sudo resize2fs -p "$loopdevice" $p2_new_size_blocks

    #clear free space
    loop_mount
    clear_free_space
    insert_autoresize_files
    loop_umount

    loop_cleanup

    echo "start= $p2_start_sector, size= $p2_new_size_sectors" | sfdisk -N 2 $image &>log/resize.log

    truncate -s $part_new_size_byte $image

    echo "Done."
}

# If this file is run directly and not sourced, run main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
