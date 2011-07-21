#!/bin/bash

# Copy this script to the gentoo livecd environment.  You must
# have an HTTP server setup which provides access to the stage3, portage snapshot, kernel-config, and chroot-script.sh.
#
# Call this script with the base URL of this server as the only
# parameter.  IE:
#   ./build.sh http://192.168.42.42/~user/zfs
#
#
# Layout of this script:
#
# This script loads the zfs driver, partitions disks, formats the
# /boot and swap partitions, and creates the zpool.  It downloads
# the initial stage files & portage snapshots and untars them
# into what will be the chroot environment.  Finally it copies
# chroot-script.sh into the chroot, chroot's, and executes 
# that script.
#
# chroot-script.sh does most of the gentoo install work of emerging
# packages, compiling the kernel etc.  Once most of the setup work
# is done, chroot-script.sh will drop to a shell inside the chroot
# and give you an opportunity emerge any addititonal packages or
# do anything else you might need to do in the chroot.  
#
# You should at this point SET YOUR ROOT PASSWORD! =)

# When you exit that shell, chroot-script.sh will exit, and 
# you'll be returned to the final part of this build.sh.  
# At that point, this script will umount filesystems and 
# prepare the system to reboot.  You will be dropped back to 
# your shell one more time, and you'll have a chance to make 
# any final adjustments.  Reboot, remove your install media 
# from the system, and with any luck you'll end up in your
# shiny new ZFS root Gentoo system.

set -e
set -x

URL=$1
STAGE3=stage3-amd64-20110707.tar.bz2
SNAPSHOT=portage-20110704.tar.bz2

# Kernel version we want, KV with the -gentoo- flag for initramf & kernel,
# KVP with just the version for portage.
KV=2.6.38-gentoo-r6
KVP=2.6.38-r6
# Note: these are in chroot-script.sh too.

# Load the ZFS kernel module.  You may need to constrain the size of your
# l2arc, especially if you're running on constrained hardware like a testing
# system or a VM.  If your system locks up under I/O, you probably need to
# limit the l2arc.  If it's going to, it'll probably happen when we try to
# uncompress the stage3 tarball.
# 128MB: 0x8000000
# 512MB: 0x20000000
modprobe zfs zfs_arc_max=0x20000000

## This next chunk is just trying to clean up from previous runs of
## this script in case we're re-running it.

umount -f /mnt/gentoo/boot || true
umount -f /mnt/gentoo/dev || true
umount -f /mnt/gentoo/proc || true
zfs umount -a || /bin/true
umount -f /mnt/gentoo || /bin/true

swapoff /dev/md1 || /bin/true

sleep 1

# Shutdown any md mirrors
for f in /dev/md* ; do
  mdadm --stop $f || /bin/true
done

# Try to import the pool if it wasn't, then destroy it.
zpool import -f -N rpool || /bin/true
zpool destroy rpool || /bin/true
sleep 1

## End of cleanup.

# Loop over the four drives we're using
for f in a b ; do
  # Make sure any previous mirror is good and dead...
  mdadm --zero-superblock /dev/sd${f}1 || /bin/true
  mdadm --zero-superblock /dev/sd${f}2 || /bin/true
  
  # Overwrite anything on the front bit of the disks that might confuse the 
  # partitioner or RAID tools.
  dd if=/dev/zero of=/dev/sd${f} bs=2M count=1
  
  ## EDIT ME:
  ## Make up some partitions.  We do 64M for boot, 
  ## 2G for swap (probably overkill), and the rest for ZFS.
  ## GNU parted doesn't seem to have a "rest of disk" option.
  ## We're using GPT here, but there's no reason MBR wouldn't work.
  parted -s -a opt /dev/sd${f} \
    mklabel gpt \
    mkpart boot 1M 64M \
    align-check optimal 1 \
    mkpart swap 64M 2052M \
    align-check optimal 2 \
    mkpart tank 2052M 34.4G \
    align-check optimal 3
done

# Create plain-old md mirrors for the boot partition
mdadm --create --verbose /dev/md0 --level=1 --raid-devices=2 \
  --metadata=0.90 /dev/sd[ab]1
  
# We're going with a RAID-1 for safety on the swap.  You could
# do RAID-0 for better performance at the expense of crashing the
# system if you loose a drive.
mdadm --create --verbose /dev/md1 --level=1 --raid-devices=2 \
  --metadata=0.90 /dev/sd[ab]2

# Make file systems on the md's
mke2fs /dev/md0
mkswap /dev/md1

## 
## This is where the real ZFS stuff begins.  
## If you're taking notes, start now...
##

# Create the pool.  We're doing RAID-5 on four SCSI disks.  Adjust
# as needed.  We need to umount the new pool right after so we can
# change the mount point & options
zpool create -f rpool mirror sda3 sdb3
zfs umount rpool

# Set the mount point of the new pool to root and mark it NOT mountable.
# We'll actually mount a different dataset as root
zfs set mountpoint=/mnt/gentoo rpool
zfs set canmount=off rpool

# Create a dataset for the filesystem root and set its mountpoint
# so it won't get automounted.  Initrd will do it instead.
zfs create rpool/ROOT
zfs set mountpoint=legacy rpool/ROOT

## If you're *not* using RAID-Z, you can set bootfs here, and you
## won't be need to pass a root=... param to grub.  You can't boot
## off RAID-Z (only mirror), so zpool won't let you set this for a 
## RAID-Z pool.
# zpool set bootfs=rpool/ROOT rpool

# Now mount the rootfs in the usual place for the chroot.
mount -t zfs rpool/ROOT /mnt/gentoo

# Create some datasets to keep things organized.  You can break this up
# as you like, but you must have /bin, /sbin, /etc, /dev, /lib* all inside
# rpool/ROOT.
zfs create rpool/home
zfs create rpool/usr
zfs create rpool/usr/local
zfs create rpool/usr/portage
zfs create rpool/usr/src
zfs create rpool/var
zfs create rpool/var/log

# Build an mdadm.conf from the live config & store it in the chroot.
mkdir -p /mnt/gentoo/etc
mdadm --detail --scan >> /mnt/gentoo/etc/mdadm.conf

# Copy over zpool cache.  If you skip this, you'll have to play some games in
# Dracut's emergency holographic shell to get it fixed.
mkdir /mnt/gentoo/etc/zfs
cp /etc/zfs/zpool.cache /mnt/gentoo/etc/zfs/zpool.cache

# Copy in a starting kernel config.
mkdir /mnt/gentoo/etc/kernels

## You could use the one from the livecd, but you'll need to install some
## extra firmware for the ATM drivers.
### cp /proc/config.gz /mnt/gentoo/etc/kernels
### gunzip /mnt/gentoo/etc/kernels/config.gz
### mv /mnt/gentoo/etc/kernels/config /etc/kernels/kernel-config-x86_64-${KV}
## Instead, we'll use one we've trimmed down a bit.  You might leave this out
## and choose to run menuconfig instead for a more customized system.
wget ${URL}/install/kernel-config
mv kernel-config /mnt/gentoo/etc/kernels/kernel-config-x86_64-${KV}

# Mount up the boot partition & turn on the swap.
mkdir -p /mnt/gentoo/boot
mount /dev/md0 /mnt/gentoo/boot
swapon /dev/md1

# Download the stage & snapshot we'll be using.
cd /mnt/gentoo
wget ${URL}/dist/${STAGE3}
wget ${URL}/dist/${SNAPSHOT}
wget ${URL}/install/chroot-script.sh

# Un-tar the stage & portage snapshot.
## NOTE: If your install locks up at this point, you probably need to limit
## your l2arc size (see the top of this script).
tar -xvjpf ${STAGE3}
tar -xvjf ${SNAPSHOT} -C /mnt/gentoo/usr

# Need our DNS servers
cp -L /etc/resolv.conf /mnt/gentoo/etc/

# Bind over pseudo-filesystems
mount -t proc none /mnt/gentoo/proc
mount --rbind /dev /mnt/gentoo/dev

## Normally we're run mirror select, but the version of Python in the livecd
## seems to offend it.  Might be possible to do it inside the chroot instead.
#mirrorselect -i -o >> /mnt/gentoo/etc/make.conf
#mirrorselect -i -r -o >> /mnt/gentoo/etc/make.conf

## Write some settings out to make.conf in the chroot.
## We set some minimal USE flags, enable ZFS in Dracut, and use our
## favorite local mirrors (you should change these).  You'll probably
## also want to adjust your make opts based on how many CPU's you have.
cat >> /mnt/gentoo/etc/make.conf <<EOF
DRACUT_MODULES="zfs"

USE="mmx sse sse2 sse3 ssl zfs bash-completion vmware_guest_linux git subversion zfs -dso lzma gpg curl wget"

MAKEOPTS="-j5"

GENTOO_MIRRORS="http://mirror.datapipe.net/gentoo http://gentoo.mirrors.easynews.com/linux/gentoo/ http://lug.mtu.edu/gentoo/ rsync://mirrors.rit.edu/gentoo/ http://mirrors.rit.edu/gentoo/"
SYNC="rsync://rsync5.us.gentoo.org/gentoo-portage"
EOF

echo "Entering chroot now..."
chmod +x /mnt/gentoo/chroot-script.sh
chroot /mnt/gentoo /chroot-script.sh
## Should wait here until we exit the chroot

## Time Passes...

## Should be back outside chroot now.
echo "We're back from chroot.  Getting system ready to reboot."

# Setup /etc/fstab in the chroot with our boot, swap, and a legacy entry for root.
cat > /mnt/gentoo/etc/fstab <<FSTAB
/dev/md0                /boot           ext2            noauto,noatime  1 2
/dev/md1                none            swap            sw              0 0
rpool/ROOT              /               zfs             noatime         0 0
/dev/cdrom              /mnt/cdrom      auto            noauto,ro       0 0
FSTAB

# Build grub.conf in the chroot
cat > /mnt/gentoo/boot/grub/grub.conf <<GCONF
default 0
timeout 3 
splashimage=(hd0,0)/boot/grub/splash.xpm.gz 
 
title Gentoo Linux           
root (hd0,0) 
kernel /boot/kernel-genkernel-x86_64-${KV} root=zfs:rpool/ROOT 
initrd /boot/initramfs-genkernel-x86_64-${KV}
GCONF

cd
zfs umount -a
zfs set mountpoint=/ rpool
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -l /mnt/gentoo{/boot,/proc,}
zpool export rpool

echo "It should be safe to remove the installation CD and reboot now."
echo "You might want to check the output of 'mount' and 'zfs mount'. "
echo "Note that you *may* need to boot with the 'zfs_force=1' parameter"
echo "to grub for your first boot in the event your hostid is different"
echo "in the live system than it was for the livecd."
echo " "
echo "Reboot when you're ready.  Don't forget to remove the installcd."
