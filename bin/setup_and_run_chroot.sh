#!/bin/bash

# Exit on any error
set -e

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Define variables
CHROOT_PATH="/mnt/debian_chroot"
DEBOOTSTRAP_VARIANT="minbase"
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian/"
DATA_COLLECTION_SCRIPT="auto_term.py"
COMMANDS_FILE="bash_cmds.txt"

INSTALL="python3,python3-pyte,bash,sudo"

# Create chroot directory if it doesn't exist
mkdir -p $CHROOT_PATH

# Install debootstrap if not already installed
if ! command -v debootstrap &> /dev/null; then
    apt-get update
    apt-get install -y debootstrap
fi

# Setup the chroot environment
echo "Setting up Debian chroot environment..."
debootstrap --include $INSTALL --variant=$DEBOOTSTRAP_VARIANT $DEBIAN_RELEASE $CHROOT_PATH $DEBIAN_MIRROR

# Copy the data collection script into the chroot
echo "Copying data collection script into chroot..."
cp $DATA_COLLECTION_SCRIPT $CHROOT_PATH/root/

# Copy the commands file into the chroot
echo "Copying commands file into chroot..."
cp $COMMANDS_FILE $CHROOT_PATH/root/

# Make the script executable
chmod +x $CHROOT_PATH/root/$DATA_COLLECTION_SCRIPT

# Prepare the chroot environment
echo "Preparing chroot environment..."
mount -t proc proc $CHROOT_PATH/proc
mount -t sysfs sys $CHROOT_PATH/sys
mount -o bind /dev $CHROOT_PATH/dev
mount -t devpts none $CHROOT_PATH/dev/pts

# Function to clean up mounts
cleanup() {
    echo "Cleaning up..."
    umount $CHROOT_PATH/proc
    umount $CHROOT_PATH/sys
    umount $CHROOT_PATH/dev/pts
    umount $CHROOT_PATH/dev
}

# Set trap to ensure cleanup on exit
trap cleanup EXIT

# Run the data collection script inside the chroot
echo "Running data collection script in chroot..."
chroot $CHROOT_PATH /bin/bash -c "cd /root && python3 $DATA_COLLECTION_SCRIPT"
cp $CHROOT_PATH/root/terminal_log.jsonl ./
chown user:user ./terminal_log.jsonl
echo "Data collection complete. Output saved in ./terminal_log.jsonl"

# Cleanup is handled by the trap
