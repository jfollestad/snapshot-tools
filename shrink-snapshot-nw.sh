#!/bin/bash

function local_cleanup() {
    if losetup "$loopback" &>/dev/null; then
        sudo losetup -d "$loopback"
    fi
    #TODO Set up umount if mounted
}

function usage() {
    echo "Usage: $0 [-sdrpzh] imagefile.image [newimagefile.image]"
    echo ""
    echo "  -s: Skip autoexpand"
    echo "  -d: Debug mode on"
    echo "  -r: Use advanced repair options"
    echo "  -z: Gzip compress image after shrinking"
    echo "  -h: display help text"
}

function set_defaults() {
    should_skip_autoexpand=false
    debug=false
    repair=false
    gzip_compress=false
}

function parse() {
    while getopts ":sdrzh" opt; do
        case "${opt}" in
        s) should_skip_autoexpand=true ;;
        d) debug=true ;;
        r) repair=true ;;
        z) gzip_compress=true ;;
        h) help ;;
        *) usage ;;
        esac
    done
    shift $((OPTIND - 1))

    src="$1"
    image="$1"
}

function usage_checks() {
    if [[ -z "$image" ]]; then
        usage
    fi
    if [[ ! -f "$image" ]]; then
        echo $LINENO "$image is not a file..."
        exit -2
    fi
}

function check_dependencies() {
    for command in parted losetup tune2fs md5sum e2fsck resize2fs; do
        command -v $command >/dev/null 2>&1
        if (($? != 0)); then
            echo $LINENO "$command is not installed."
            exit -4
        fi
    done
}

function check_new_file() {
    #Copy to new file if requested
    if [ -n "$2" ]; then
        echo "Copying $1 to $2..."
        cp --reflink=auto --sparse=always "$1" "$2"
        if (($? != 0)); then
            echo $LINENO "Could not copy file..."
            exit -5
        fi
        old_owner=$(stat -c %u:%g "$1")
        chown "$old_owner" "$2"
        image="$2"
    else
        echo "changing in place"
    fi
}

function setup_traps() {
    # local_cleanup at script exit
    trap local_cleanup ERR EXIT
}

function gather_info() {
    echo "Gatherin data"
    beforesize=$(ls -lh "$image" | cut -d ' ' -f 5)
    parted_output=$(sudo parted -ms "$image" unit B print | tail -n 1)
    partnum=$(echo "$parted_output" | cut -d ':' -f 1)
    partstart=$(echo "$parted_output" | cut -d ':' -f 2 | tr -d 'B')
    loopback=$(sudo losetup -f --show -o "$partstart" "$image")
    tune2fs_output=$(sudo tune2fs -l "$loopback")
    currentsize=$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)
    blocksize=$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)
}

function pre_shrink_logging() {
    echo "$LINENO $tune2fs_output $currentsize $blocksize"
}

function check_and_set_autoexpand() {
    #Check if we should make pi expand rootfs on next boot
    if [ "$should_skip_autoexpand" = false ]; then
        #Make pi expand rootfs on next boot
        #mountdir=$(mktemp -d)
        mount "$loopback" "$mountdir"

        if [ "$(md5sum "$mountdir/etc/rc.local" | cut -d ' ' -f 1)" != "0542054e9ff2d2e0507ea1ffe7d4fc87" ]; then
            echo "Creating new /etc/rc.local"
            mv "$mountdir/etc/rc.local" "$mountdir/etc/rc.local.bak"
            #####Do not touch the following lines#####

            # $mountdir/etc/rc.local is created. Fix with a custom solution

            #####End no touch zone#####
            chmod +x "$mountdir/etc/rc.local"
        fi
        umount "$mountdir"
    else
        echo "Skipping autoexpanding process..."
    fi
}

function checkFilesystem() {
    #Make sure filesystem is ok

    echo "Checking filesystem"
    sudo e2fsck -pf "$loopback"
    (($? < 4)) && return

    echo "Filesystem error detected!"

    echo "Trying to recover corrupted filesystem"
    sudo e2fsck -y "$loopback"
    (($? < 4)) && return

    if [[ $repair == true ]]; then
        echo "Trying to recover corrupted filesystem - Phase 2"
        sudo e2fsck -fy -b 32768 "$loopback"
        (($? < 4)) && return
    fi
    echo $LINENO "Filesystem recoveries failed. Giving up..."
    exit -9
}

function get_minsize() {
    #TODO What is this?
    if ! minsize=$(sudo resize2fs -P "$loopback"); then
        rc=$?
        error $LINENO "resize2fs failed with rc $rc"
        exit -10
    fi
}

function check_if_minsize() {
    minsize=$(cut -d ':' -f 2 <<<"$minsize" | tr -d ' ')
    echo $LINENO $minsize
    if [[ $currentsize -eq $minsize ]]; then
        echo $LINENO "Image already shrunk to smallest size"
        exit -11
    fi
}

function add_free_space() {
    #Add some free space to the end of the filesystem
    extra_space=$(($currentsize - $minsize))
    echo $LINENO $extra_space
    for space in 5000 1000 100; do
        if [[ $extra_space -gt $space ]]; then
            minsize=$(($minsize + $space))
            break
        fi
    done
    echo $LINENO $minsize
}

function shrink_fs() {
    #Shrink filesystem
    echo "Shrinking filesystem"
    sudo resize2fs -p "$loopback" $minsize
    if [[ $? != 0 ]]; then
        echo $LINENO "resize2fs failed"
        sudo mount "$loopback" "$mountdir"
        #mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
        sudo umount "$mountdir"
        sudo losetup -d "$loopback"
        exit -12
    fi
    sleep 1
}

function shrink_partition() {
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
    if ! endresult=$(sudo parted -ms "$image" unit B print free); then
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

function compress_image() {
    if [[ $gzip_compress == true ]]; then
        info "Gzipping the shrunk image"
        if [[ ! $(gzip -f9 "$image") ]]; then
            image=$image.gz
        fi
    fi
}

function bragging() {
    aftersize=$(ls -lh "$image" | cut -d ' ' -f 5)
    logVariables $LINENO aftersize

    info "Shrunk $image from $beforesize to $aftersize"
}

function main() {
    set_defaults
    parse "$@"
    usage_checks
    check_dependencies
    check_new_file $1 $2
    setup_traps
    gather_info
    #pre_shrink_logging
    mountdir=$(mktemp -d)
    #check_and_set_autoexpand
    checkFilesystem
    check_fs_size
    check_if_minsize
    add_free_space
    shrink_fs
    #shrink_partition

    echo "success: All is well."
}

# If this file is run directly and not sourced, run main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
