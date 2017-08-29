#!/bin/bash

# Date format, used in the image file name
mydate=`date +%Y%m%d-%H%M`

# Size of the image and boot partitions
imgsize="2G"
bootsize="100M"

# Location of the build environment, where the image will be mounted during build
ourpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
buildenv="$ourpath/BuildEnv"

# folders in the buildenv to be mounted, one for rootfs, one for /boot
# Recommend that you don't change these!
rootfs="${buildenv}/rootfs"
bootfs="${rootfs}/boot"

##############################
# No need to edit under this #
##############################

distrib_name="debian"
deb_mirror="https://mirrors.kernel.org/debian/"
deb_release="stretch"
deb_arch="arm64"

echo "DEB-BUILDER: Building $distrib_name Image"

# Check to make sure this is ran by root
if [ $EUID -ne 0 ]; then
  echo "DEB-BUILDER: this tool must be run as root"
  exit 1
fi

# make sure no builds are in process (which should never be an issue)
if [ -e ./.build ]; then
	echo "DEB-BUILDER: Build already in process, aborting"
	exit 1
else
	touch ./.build
fi

# Start by making our build dir
mkdir -p $buildenv/toolchain
cd $buildenv

# Setup our build toolchain for this
echo "DEB-BUILDER: Setting up Toolchain"
wget https://releases.linaro.org/components/toolchain/binaries/7.1-2017.05/aarch64-linux-gnu/gcc-linaro-7.1.1-2017.05-x86_64_aarch64-linux-gnu.tar.xz
tar xf gcc-linaro-7.1.1-2017.05-x86_64_aarch64-linux-gnu.tar.xz -C $buildenv/toolchain
rm gcc-linaro-7.1.1-2017.05-x86_64_aarch64-linux-gnu.tar.xz
export PATH=$buildenv/toolchain/gcc-linaro-7.1.1-2017.05-x86_64_aarch64-linux-gnu/bin:$PATH
export GCC_COLORS=auto
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64

# Build our dependencies
echo "DEB-BUILDER: Building Dependencies"
mkdir -p $ourpath/requires
mkdir -p $buildenv/git
cd $buildenv/git

# Build ARM Trusted Firmware
git clone https://github.com/apritzel/arm-trusted-firmware.git --depth 1 -b allwinner
cd arm-trusted-firmware
make PLAT=sun50iw1p1 DEBUG=1 bl31
export BL31=$buildenv/git/arm-trusted-firmware/build/sun50iw1p1/debug/bl31.bin
cd $buildenv/git

# Build U-Boot
git clone https://github.com/u-boot/u-boot.git --depth 1 -b master
cd u-boot
# If we have patches, apply them
if [[ -d $ourpath/patches/u-boot/ ]]; then
	for file in $ourpath/patches/u-boot/*.patch; do
		echo "Applying u-boot patch $file"
		git apply $file
	done
fi
cp $ourpath/configs/u-boot/sun50i-h5-nanopi-neo2.dts ./arch/arm/dts/sun50i-h5-nanopi-neo2.dts
cp $ourpath/configs/u-boot/nanopi_neo2_defconfig ./configs/nanopi_neo2_defconfig
make nanopi_neo2_defconfig
make -j`getconf _NPROCESSORS_ONLN`
cp spl/sunxi-spl.bin $ourpath/requires/
cp u-boot.itb $ourpath/requires/
cd $buildenv/git

# Build the Linux Kernel
mkdir linux-build && cd ./linux-build
git clone https://github.com/torvalds/linux.git --depth 1 -b v4.13-rc7
cd linux
# If we have patches, apply them
if [[ -d $ourpath/patches/kernel/ ]]; then
	for file in $ourpath/patches/kernel/*.patch; do
		echo "Applying kernel patch $file"
		git apply $file
	done
fi
cp $ourpath/configs/kernel/sun50i-h5-nanopi-neo2.dts ./arch/arm64/boot/dts/allwinner/sun50i-h5-nanopi-neo2.dts
cp $ourpath/configs/kernel/nanopi_neo2_defconfig ./arch/arm64/configs/nanopi_neo2_defconfig
make nanopi_neo2_defconfig
make -j`getconf _NPROCESSORS_ONLN` deb-pkg dtbs
cp arch/arm64/boot/dts/allwinner/sun50i-h5-nanopi-neo2.dtb $ourpath/requires/
cd ../
cp linux-*.deb $ourpath/requires/
cd $buildenv

# Before we start up, make sure our required files exist
for file in u-boot.itb sunxi-spl.bin sun50i-h5-nanopi-neo2.dtb; do
	if [[ ! -e "$ourpath/requires/$file" ]]; then
		echo "DEB-BUILDER: Error, required file './requires/$file' is missing!"
		rm $ourpath/.build
		exit 1
	fi
done

# Create the buildenv folder, and image file
echo "DEB-BUILDER: Creating Image file"
image="${buildenv}/headless_${distrib_name}_${deb_release}_${deb_arch}_${mydate}.img"
fallocate -l $imgsize "$image"
device=`losetup -f --show $image`
echo "DEB-BUILDER: Image $image created and mounted as $device"

# Format the image file partitions
echo "DEB-BUILDER: Setting up MBR/Partitions"
fdisk $device << EOF
o
n
p
1

+$bootsize
t
c
n
p
2


w
EOF

# Some systems need partprobe to run before we can fdisk the device
partprobe

# Install U-Boot before we mount
echo "DEB-BUILDER: Installing U-Boot"
dd if=$ourpath/requires/sunxi-spl.bin of=$device bs=8k seek=1
dd if=$ourpath/requires/u-boot.itb of=$device bs=8k seek=5

# Mount the loopback device so we can modify the image, format the partitions, and mount/cd into rootfs
device=`kpartx -va $image | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
sleep 1 # Without this, we sometimes miss the mapper device!
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2
echo "DEB-BUILDER: Formatting Partitions"
mkfs.vfat $bootp -n BOOT
mkfs.ext4 $rootp -L root
mkdir -p $rootfs
mount $rootp $rootfs
cd $rootfs

#  start the debootstrap of the system
echo "DEB-BUILDER: Mounted partitions, debootstraping..."
debootstrap --no-check-gpg --foreign --arch $deb_arch $deb_release $rootfs $deb_mirror
cp /usr/bin/qemu-aarch64-static usr/bin/
LANG=C chroot $rootfs /debootstrap/debootstrap --second-stage

# Mount the boot partition
mount -t vfat $bootp $bootfs

# Start adding content to the system files
echo "DEB-BUILDER: Setting up device specific tweaks"

# apt mirrors
echo "deb $deb_mirror $deb_release main contrib non-free
deb-src $deb_mirror $deb_release main contrib non-free" > etc/apt/sources.list

# U-Boot commands
cat << EOF > boot/boot.cmd
# Recompile with:
# mkimage -C none -A arm -T script -d boot.cmd boot.scr

setenv fsck.repair yes
setenv ramdisk initramfs.cpio.gz
setenv kernel Image

setenv env_addr 0x45000000
setenv kernel_addr 0x46000000
setenv ramdisk_addr 0x47000000
setenv dtb_addr 0x48000000

fatload mmc 0 \${kernel_addr} \${kernel}
fatload mmc 0 \${ramdisk_addr} \${ramdisk}
fatload mmc 0 \${dtb_addr} sun50i-h5-nanopi-neo2.dtb
fdt addr \${dtb_addr} 0x100000

# setup MAC address
fdt set ethernet0 local-mac-address \${mac_node}

setenv bootargs console=ttyS0,115200 earlyprintk root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait fsck.repair=\${fsck.repair} panic=10 \${extra}
booti \${kernel_addr} \${ramdisk_addr}:500000 \${dtb_addr}
EOF

# Mounts
echo "proc            /proc           proc    defaults        0       0
/dev/mmcblk0p1  /boot           vfat    defaults        0       0
/dev/mmcblk0p2	/				ext4	defaults		0		1
" > etc/fstab

# Hostname
echo "${distrib_name}" > etc/hostname
echo "127.0.1.1	${distrib_name}" >> etc/host

# Networking
echo "auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp
iface eth0 inet6 dhcp
" > etc/network/interfaces

# Console settings
echo "console-common	console-data/keymap/policy	select	Select keymap from full list
console-common	console-data/keymap/full	select	us
" > debconf.set

# Third Stage Setup Script (most of the setup process)
cat << EOF > third-stage
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates e2fsprogs ntp parted curl \
fake-hwclock locales console-common openssh-server less vim net-tools \
initramfs-tools u-boot-tools
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
echo "root:debian" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
sed -i 's|#PermitRootLogin prohibit-password|PermitRootLogin yes|g' /etc/ssh/sshd_config
echo 'HWCLOCKACCESS=no' >> /etc/default/hwclock
echo 'RAMTMP=yes' >> /etc/default/tmpfs
rm -f third-stage
EOF
chmod +x third-stage
LANG=C chroot $rootfs /third-stage

# Setup our boot partition so we can actually boot
# we also need to do some kernel moving n shit due to discrepencies in stuff
cp -R $ourpath/requires root
cat << EOF > forth-stage
#!/bin/bash
dpkg -i /root/requires/linux-*.deb
mv /root/requires/sun50i-h5-nanopi-neo2.dtb /boot/sun50i-h5-nanopi-neo2.dtb
mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr
mv /boot/vmlinuz-* /boot/Image.gz
gunzip /boot/Image.gz
rm -rf /root/requires
mv /boot/initrd.img-* /boot/initramfs.cpio.gz
rm -f forth-stage
EOF
chmod +x forth-stage
LANG=C chroot $rootfs /forth-stage


echo "DEB-BUILDER: Cleaning up build space/image"

# Cleanup Script
echo "#!/bin/bash
update-rc.d ssh remove
apt-get autoclean
apt-get --purge -y autoremove
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
service ntp stop
rm -rf /boot.bak
rm -f cleanup
" > cleanup
chmod +x cleanup
LANG=C chroot $rootfs /cleanup

# startup script to generate new ssh host keys
rm -f etc/ssh/ssh_host_*
echo "DEB-BUILDER: Deleted SSH Host Keys. Will re-generate at first boot by user"
cat << EOF > etc/init.d/first_boot
#!/bin/sh
### BEGIN INIT INFO
# Provides:          first_boot
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Generates new ssh host keys on first boot & resizes rootfs
# Description:       Generates new ssh host keys on first boot & resizes rootfs
### END INIT INFO

# Generate SSH keys & enable SSH
ssh-keygen -f /etc/ssh/ssh_host_rsa_key -t rsa -N ""
ssh-keygen -f /etc/ssh/ssh_host_dsa_key -t dsa -N ""
service ssh start
update-rc.d ssh defaults

# Resize root disk
fdisk /dev/mmcblk0 << LEL
d
2

n
p
2


n

w
LEL
partprobe
resize2fs /dev/mmcblk0p2

# Cleanup
update-rc.d first_boot remove
rm -f \$0
EOF
chmod a+x etc/init.d/first_boot
LANG=C chroot $rootfs update-rc.d first_boot defaults
LANG=C chroot $rootfs update-rc.d first_boot enable

# Lets cd back
cd $buildenv && cd ..

# Unmount some partitions
echo "DEB-BUILDER: Unmounting Partitions"
umount $bootp
umount $rootp
kpartx -d $image

# Properly terminate the loopback devices
echo "DEB-BUILDER: Finished making the image $image"
dmsetup remove_all
losetup -D

# Move image out of builddir, as buildscript will delete it
echo "DEB-BUILDER: Moving image out of builddir and compressing"
mkdir -p $ourpath/output
mv ${image} $ourpath/output/headless_${distrib_name}_${deb_release}_${deb_arch}_${mydate}.img
gzip $ourpath/output/headless_${distrib_name}_${deb_release}_${deb_arch}_${mydate}.img
mkdir -p $ourpath/output/kernel
mv $ourpath/requires/linux-*.deb $ourpath/output/kernel
mv $ourpath/requires/sun*.dtb $ourpath/output/kernel
mkdir -p $ourpath/output/u-boot
mv $ourpath/requires/sunxi-spl.bin $ourpath/output/u-boot
mv $ourpath/requires/u-boot.itb $ourpath/output/u-boot
cd $ourpath

echo "DEB-BUILDER: Cleaning Up"
rm $ourpath/.build
rm -r $ourpath/requires
rm -r $buildenv
echo "DEB-BUILDER: Finished!"
exit 0