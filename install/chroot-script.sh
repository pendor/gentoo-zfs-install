#!/bin/bash

set -e
set -x

env-update
source /etc/profile

KV=2.6.38-gentoo-r6
KVP=2.6.38-r6
# Note these are in build.sh too.

# We need layman to get our portage overlays for ZFS & Genkernel.
emerge -v layman

# Insert the laymay overlay URL for the ZFS & genkernel stuff.
cp /etc/layman/layman.cfg /etc/layman/layman-orig.cfg
sed '/^\s*overlays\s*:/ a\
    https://raw.github.com/pendor/gentoo-zfs-overlay/master/overlay.xml' \
    /etc/layman/layman-orig.cfg > /etc/layman/layman.cfg

# Refresh the Layman overlay list and add zfs to the active list
layman -f
layman -a zfs

# Once we have an overlay active, it's safe to add layman into make.conf
echo "source /var/lib/layman/make.conf" >> /etc/make.conf

# Add portage keywords to allow installing newer versions of genkernel and dracut
mkdir -p /etc/portage/package.keywords
echo "sys-kernel/genkernel **" > /etc/portage/package.keywords/genkernel
echo "=sys-kernel/dracut-010-r3 ~amd64" > /etc/portage/package.keywords/dracut

## FIXME: Edit the Genkernel config to set makeopts

# There's a circular dependency here...  We want to use genkernel to build
# the kernel, but the ZFS driver build doesn't work until there's a valid built
# kernel tree on the disk, and genkernel depends zfs.  We'll exclude ZFS from
# the use flags for now and just do sources/genkernel, then build a kernel
# without ZFS.  Then we'll have to build ZFS & rebuilt the initramfs.
USE="-zfs" emerge -v =sys-kernel/gentoo-sources-${KVP} =sys-kernel/genkernel-9999
genkernel --menuconfig all

# Unmask latest versions of spl & zfs, then build them.
echo "sys-fs/zfs **" > /etc/portage/package.keywords/zfs
echo "sys-devel/spl **" >> /etc/portage/package.keywords/zfs
emerge -v =sys-devel/spl-0.6.0_rc5 =sys-fs/zfs-0.6.0_rc5 =sys-kernel/genkernel-9999

## FIXME: Genkernel config file add zfs
# edit /etc/genkernel.conf++zfs, build again
genkernel --no-clean --no-mrproper --zfs --loglevel=5 all

# Emerge some basic system stuff.  Substitute other loggers, crons, etc. as preferred.
emerge -v metalog vixie-cron app-misc/screen dhcpcd mdadm grub joe sys-block/parted

# Add services to startup. zfs and udev must be in boot for anything to work.
rc-update add zfs boot
rc-update add udev boot
rc-update add mdadm default

# Add services as desired.
rc-update add metalog default
rc-update add vixie-cron default

## You might not want this if you're doing static IP...
rc-update add dhcpcd default

# Setup grub on all four devices
cat /proc/mounts | grep -v rootfs > /etc/mtab
for dev in 0 1 ; do
  grub --batch <<EOG
root (hd${dev},0)
setup (hd${dev})
quit
EOG
done

echo "The ZFS portion of things is done, and this should give a bootable system."
echo "You can emerge any additional packages and configure the system as you like"
echo "now.  When you're done, exit this shell, and we'll escape the chroot and"
echo "get ready to reboot."
echo " "
echo "DON'T FORGET TO SET YOUR ROOT PASSWORD. "
echo " "

exec /bin/bash
