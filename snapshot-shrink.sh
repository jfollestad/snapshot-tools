#!/bin/bashg

#TODO Logfile
#TODO echoes
#TODO add line-number to errors? echo -n "$SCRIPTNAME: ERROR occured in line $1: "
#TODO $LINENO
#TODO basename $0
#TODO dirname

function local_cleanup() {
    loop_umount
    loop_cleanup
}

function setup_traps() {
    # local_cleanup at script exit
    trap local_cleanup ERR EXIT
}

function usage() {
    echo "Usage: $0 [-sdrpzh] imagefile.img [newimagefile.img]"
    echo ""
    echo "  -s: Skip autoexpand"
    echo "  -d: Debug mode on"
    echo "  -r: Reset host ssh keys"
    echo "  -z: Gzip compress image after shrinking"
    echo "  -h: display help text"
}

function set_defaults() {
    skip_autoexpand=false
    debug=false
    gzip_compress=false
    reset_host_ssh_keys=false
}

function parse() {
    while getopts ":sdzh" opt; do
        case "${opt}" in
        s) skip_autoexpand=true ;;
        d) debug=true ;;
        r) reset_host_ssh_keys=true ;;
        z) gzip_compress=true ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    input="$1"
    output="$2"
}

function check_usage() {
    if [[ -z "$input" ]]; then
        usage
    fi
    if [[ ! -f "$input" ]]; then
        echo $LINENO "$input is not a file..."
        exit 1
    fi
    if [ -n "$output" ]; then #TODO check if force is active, and ask for user intervention.
        #TODO test if a file exists first
        echo "Removing old outputfile..."
        rm "$output"
        echo "...gone."
    fi
    #TODO Logfile?

}

function check_new_file() {
    #TODO Duplicate of the above function?
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
    p2_start_sector=$(sfdisk -J $image | jq ".partitiontable.partitions[1].start")
    echo "p2_start_sector: $p2_start_sector"

    p2_start=$(($p2_start_sector * 512))
    echo "p2_start: $p2_start"
}

function loop_setup() {
    #Create loop
    loopdevice=$(sudo losetup -f --show -o "$p2_start" "$image")
    echo "loopdevice: $loopdevice"
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
        unset mountdir
    fi
}

function check_filesystem() {
    #check filesystem
    sudo e2fsck -fy "$loopdevice"
    echo "e2fsck: $?" #If not catched, this causes an error later. Unknown why.
    if [[ ! $? < 4 ]]; then
        echo "Filesystem recoveries failed."
        exit 1
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

    #TODO Make the following check work
    #if [[ $currentsize -eq $minsize ]]; then
    #    error $LINENO "Image already shrunk to smallest size"
    #    exit -11
    #fi

    extra_space_blocks=$((134217728 / $p2_block_size)) # 128MB / blocksize
    echo "extra_space_blocks: $extra_space_blocks"

    p2_new_size_blocks=$(($p2_minsize_blocks + $extra_space_blocks))
    echo "p2_new_size_blocks: $p2_new_size_blocks"

    p2_new_size_sectors=$(($p2_new_size_blocks * 8)) && echo "p2_new_size_blocks: $p2_new_size_blocks"
    echo "p2_new_size_sectors: $p2_new_size_sectors"

    part_new_size_sectors=$(($p2_start_sector + $p2_new_size_sectors))

    part_new_size_byte=$(($part_new_size_sectors * 512))
    echo "part_new_size_byte: $part_new_size_byte"
}

function clear_free_space() {
    echo "Writing zeroes in unused space..."
    sudo dd if=/dev/zero | pv | sudo dd of="$mountdir/null.file" bs=512
    sudo rm $mountdir/null.file
    echo "... and done zeroing space."
}

function insert_autoresize_files() {
    #TODO Check if skip is true
    echo "adding auto resize on boot files..."
    scriptpath=$(dirname $(realpath $0))
    sudo touch $mountdir/.first_boot
    sudo cp $scriptpath/src/aafirstboot $mountdir/
    sudo rm $mountdir/resize.log
    echo "... done."
}

function reset_ssh() {
    if [ $reset_host_ssh_keys = true ]; then
        echo "Creating /.reset_host_ssh_keys"
        sudo touch $mountdir/.reset_host_ssh_keys
    fi
}

function resize_fs() {
    echo "resizing filesystem"
    #resize the filesystem
    sudo resize2fs -p "$loopdevice" $p2_new_size_blocks
    #TODO Check for success/fail
    #TODO Remove the autosizefiles if the above fails?
}

function resize_part() {
    echo "resizing partition"
    #Resize partition
    echo "start= $p2_start_sector, size= $p2_new_size_sectors" | sfdisk -N 2 $image &>log/resize.log
    #TODO Check for success/fail
}

function resize_file() {
    echo "resizing file"
    #Reduce filesize
    truncate -s $part_new_size_byte $image
    #TODO Check for success/fail
    echo "... done."
}

function compress_image() {
    if [ $gzip_compress = true ]; then
        echo "Gzipping the shrunken image..."
        pv "$image" | gzip -f9 >"$image.gz"
        if [ $? = true ]; then
            rm "$image"
        fi
    fi
}

function bragging() {
    return 0
    #TODO Print size in the beginning vs. the end.
}

function main() {
    setup_traps
    set_defaults
    parse "$@"
    check_usage
    check_new_file

    gather_pre_loop_info
    loop_setup
    check_filesystem
    gather_info

    # mount, clear, set up autoresize, and unmount
    loop_mount
    insert_autoresize_files
    reset_ssh
    loop_umount

    # resize for each step, and compress
    check_filesystem
    resize_fs
    loop_mount
    clear_free_space
    loop_umount
    loop_cleanup
    resize_part
    resize_file
    compress_image

    echo "Done."
}

# If this file is run directly and not sourced, run main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
