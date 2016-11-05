#!/bin/bash

## Tested with following images:
# BBB: bone-debian-8.6-console-armhf-2016-10-30-2gb.img
# PiCorePlayer: piCorePlayer3.02.img

BASEDIR=$(pwd)
TMPDIR="$BASEDIR/tmp"

ORIG_INITRD_PI_NAME="8.0v7.gz"
IMG_SKELETON="$BASEDIR/img_skeleton.img.gz"
DEPMOD="$BASEDIR/depmod.pl"

BONE_BASE_MNT="$TMPDIR/mnt/bone"
PICORE_BASE_MNT="$TMPDIR/mnt/picore"
OUTPUT_BASE_MNT="$TMPDIR/mnt/output"

INITRD_BBB_TMPDIR="$TMPDIR/initrd/bbb"
INITRD_PICORE_TMPDIR="$TMPDIR/initrd/pi"
INITRD_OUTPUT_TMPDIR="$TMPDIR/initrd/out"
MYDATA_TMPDIR="$TMPDIR/mydata_tmp"

OUTPUT_DIR="$TMPDIR/output"

SECT_SIZE=512

function get_start_sector() {
	local FILE="$1"
	local PART_NO="$2"
	local START_SECT=$(fdisk -l "$FILE" | grep "^${FILE}${PART_NO}" |sed 's/\*//' | tr -s ' ' | cut -d ' ' -f2)
	echo -ne $(($START_SECT * $SECT_SIZE))
}

function unmount_all() {
	local MOUNT_POINTS="$BONE_BASE_MNT $PICORE_BASE_MNT $OUTPUT_BASE_MNT"
	for MNT in $MOUNT_POINTS
	do
		grep $MNT/boot /proc/mounts &> /dev/null && umount $MNT/boot
		grep $MNT/rootfs /proc/mounts &> /dev/null && umount $MNT/rootfs
	done
	return 0
}

function exit_with_error() {
	unmount_all
	exit 1
}

function mount_image_partition() {
	local IMAGE="$1"
	local DESTINATION="$2"
	local PART_NO="$3"

	mkdir -p $DESTINATION &> /dev/null || (grep $DESTINATION /proc/mounts && umount $DESTINATION)
	SECTOR=$(get_start_sector $IMAGE $PART_NO)
	mount $IMAGE $DESTINATION -o offset=$(($SECTOR)) || (echo "[-] Failed to mount partition $PART_NO from image $IMAGE !"; exit_with_error)
	return 0
}

function get_kernel_versionstring() {
	local MNT_POINT="$1"
	echo -ne $(ls "$MNT_POINT/lib/modules/")
}

function unpack_initrd() {
	local INITRD_FILE="$1"
	local DEST_DIR="$2"
	if [ ! -f $INITRD_FILE ]; then
		echo "[-] Initrd $INITRD_FILE not found!"
		exit_with_error
	fi
	[ -d $DEST_DIR ] && rm -rf $DEST_DIR
	mkdir -p $DEST_DIR
	local PWD=$(pwd)
	cd $DEST_DIR
	gunzip -c $INITRD_FILE | cpio -imd
	cd $PWD
	return 0
}

function pack_initrd() {
	local INITRD_UNPACKED="$1"
	local INITRD_DEST="$2"

	local PWD=$(pwd)
	cd $INITRD_UNPACKED
	find . | cpio -o -H newc | gzip > $INITRD_DEST
	cd $PWD
	return 0
}

function create_wireless_tcz() {
	local MODULES_DIR="$1"
	local TARGET_DIR="$2"

	[ -d $TARGET_DIR/tmp ] && rm -rf $TARGET_DIR/tmp
	mkdir -p $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/driver/staging
	mkdir -p $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/driver/net
	mkdir -p $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/net
	cp -ra $MODULES_DIR/kernel/drivers/net/wireless $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/driver/net/
	cp -ra $MODULES_DIR/kernel/drivers/staging/rtl8188eu $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/driver/staging/
	cp -ra $MODULES_DIR/kernel/drivers/staging/rtl8712 $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/driver/staging/
	cp -ra $MODULES_DIR/kernel/net/wireless $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/net/
	cp -ra $MODULES_DIR/kernel/net/mac80211 $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/net/
	mksquashfs $TARGET_DIR/tmp $TARGET_DIR/wireless-$BONE_KERNEL.tcz &> /dev/null
	md5sum $TARGET_DIR/wireless-$BONE_KERNEL.tcz > $TARGET_DIR/wireless-$BONE_KERNEL.tcz.md5.txt
	rm -rf $TARGET_DIR/tmp
	return 0
}

function create_alsa_modules_tcz() {
	local MODULES_DIR="$1"
	local TARGET_DIR="$2"

	[ -d $TARGET_DIR/tmp ] && rm -rf $TARGET_DIR/tmp
	mkdir -p $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/drivers/clk
	cp -ra $MODULES_DIR/kernel/drivers/clk/clk-s2mps11.ko $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/drivers/clk/
	cp -ra $MODULES_DIR/kernel/sound $TARGET_DIR/tmp/lib/modules/$BONE_KERNEL/kernel/
	mksquashfs $TARGET_DIR/tmp $TARGET_DIR/alsa-modules-$BONE_KERNEL.tcz &> /dev/null
	md5sum $TARGET_DIR/alsa-modules-$BONE_KERNEL.tcz > $TARGET_DIR/alsa-modules-$BONE_KERNEL.tcz.md5.txt
	rm -rf $TARGET_DIR/tmp
	return 0
}

#### MAIN ####

if [ "$#" -ne 3 ]; then
	echo "Error: Invalid Number of arguments!"
	echo "Usage: $0 beaglebone.img picoreplayer.img output.img"
	exit 2
fi

BONE_IMG="$1"
PICORE_IMG="$2"
OUTPUT_IMAGE="$3"

if [ ! -f $BONE_IMG ]; then
	echo "[-] Input BBB image $BONE_IMG not found!"
	exit_with_error
fi
if [ ! -f $PICORE_IMG ]; then
	echo "[-] Input PICORE image $PICORE_IMG not found!"
	exit_with_error
fi

echo "[+] Ensuring output directories are clean"
unmount_all
[ -d $TMPDIR ] && rm -rf $TMPDIR
mkdir -p $OUTPUT_DIR/boot
mkdir -p $OUTPUT_DIR/rootfs

echo "[+] Mounting the images"
mount_image_partition $BONE_IMG $BONE_BASE_MNT/rootfs 1
mount_image_partition $PICORE_IMG $PICORE_BASE_MNT/boot 1
mount_image_partition $PICORE_IMG $PICORE_BASE_MNT/rootfs 2

BONE_KERNEL=$(get_kernel_versionstring $BONE_BASE_MNT/rootfs)
echo "[+] Detected Beaglebone Kernel Version: $BONE_KERNEL"

echo "--------------------- BOOT ---------------------"
echo "[+] Copying uEnv.txt and boot-directory from BBB image to output-directory"
if [ -f $BONE_BASE_MNT/rootfs/uEnv.txt ]; then 
	cp -ra $BONE_BASE_MNT/rootfs/uEnv.txt $OUTPUT_DIR/boot/
else
	echo "[-] /uEnv.txt not found in baseimage!"
	exit_with_error
fi

if [ -d $BONE_BASE_MNT/rootfs/boot ]; then
	cp -ra $BONE_BASE_MNT/rootfs/boot $OUTPUT_DIR/boot/
else
	echo "[-] /boot directory not found in baseimage!"
	exit_with_error
fi

echo "[+] Verifying /boot directory"
FILES_TO_CHECK="initrd.img-$BONE_KERNEL System.map-$BONE_KERNEL vmlinuz-$BONE_KERNEL uEnv.txt"
for file in $FILES_TO_CHECK
do
	[ ! -f $OUTPUT_DIR/boot/boot/$file ] && (echo "File $file not found!"; exit_with_error)
done

echo "[+] Modifying /uEnv.txt..."
sed 's/mmcargs=setenv bootargs/mmcargs=setenv bootargs nortc/' -i $OUTPUT_DIR/boot/uEnv.txt
sed 's/root=\/dev\/mmcblk0p1/root=\${mmcroot}/' -i $OUTPUT_DIR/boot/uEnv.txt


echo "-------------------- INITRD --------------------"
echo "[+] Checking for piCore initrd existance"
if [ ! -f $PICORE_BASE_MNT/boot/$ORIG_INITRD_PI_NAME ]; then
	echo "[-] $PICORE_BASE_MNT/boot/$ORIG_INITRD_PI_NAME not found!"
	exit_with_error
fi

echo "[+] Copying Initrd to temp-dir for modification"
if [ -f $PICORE_BASE_MNT/boot/$ORIG_INITRD_PI_NAME ]; then
	cp $PICORE_BASE_MNT/boot/$ORIG_INITRD_PI_NAME $TMPDIR/initrd_pi.cpio.gz
else
	echo "[-] Failed to copy piCore Initrd..."
	exit_with_error
fi

if [ -f $OUTPUT_DIR/boot/boot/initrd.img-$BONE_KERNEL ]; then
	cp $OUTPUT_DIR/boot/boot/initrd.img-$BONE_KERNEL $TMPDIR/initrd_bbb.cpio.gz
else
	echo "[-] Failed to copy BBB Initrd..."
	exit_with_error
fi

echo "[+] Unpacking Initrd"
unpack_initrd $TMPDIR/initrd_bbb.cpio.gz $INITRD_BBB_TMPDIR
unpack_initrd $TMPDIR/initrd_pi.cpio.gz $INITRD_PICORE_TMPDIR

echo "[+] Copying kernel modules"
[ -d $INITRD_OUTPUT_TMPDIR ] && rm -rf $INITRD_OUTPUT_TMPDIR
mkdir -p $INITRD_OUTPUT_TMPDIR

cp -ra $INITRD_PICORE_TMPDIR/* $INITRD_OUTPUT_TMPDIR
rm -rf $INITRD_OUTPUT_TMPDIR/lib/modules/*
mkdir -p $INITRD_OUTPUT_TMPDIR/lib/modules/$BONE_KERNEL
cp -ra $INITRD_BBB_TMPDIR/lib/modules/$BONE_KERNEL/* $INITRD_OUTPUT_TMPDIR/lib/modules/$BONE_KERNEL

echo "[+] Copying additional squashfs module"
mkdir -p $INITRD_OUTPUT_TMPDIR/lib/modules/$BONE_KERNEL/kernel/fs/squashfs
cp -ra $BONE_BASE_MNT/rootfs/lib/modules/$BONE_KERNEL/kernel/fs/squashfs/squashfs.ko $INITRD_OUTPUT_TMPDIR/lib/modules/$BONE_KERNEL/kernel/fs/squashfs

echo "[+] Symlinking modules"
[ -d $INITRD_OUTPUT_TMPDIR/usr/local/lib/modules ] && rm -rf $INITRD_OUTPUT_TMPDIR/usr/local/lib/modules/*
ln -s "/lib/modules/$BONE_KERNEL" $INITRD_OUTPUT_TMPDIR/usr/local/lib/modules/$BONE_KERNEL
ln -s "/lib/modules/$BONE_KERNEL/kernel" $INITRD_OUTPUT_TMPDIR/lib/modules/$BONE_KERNEL/kernel.tclocal

echo "[+] Modifying /usr/sbin/startserialtty to work with TI AM335x BeagleBone Black"
cat << "EOF" > $INITRD_OUTPUT_TMPDIR/usr/sbin/startserialtty
#!/bin/sh
model=`cat /proc/device-tree/model`

if [ "${model:0:20}" = "Raspberry Pi 3 Model" ]; then
	port=ttyS0
elif [ "${model:0:26}" = "TI AM335x BeagleBone Black" ]; then
	port=ttyS0
else
	port=ttyAMA0
fi

# Start serial terminal on Raspberry Pi / Beaglebone Black
while :
do
	/sbin/getty -L $port 115200 vt100
done
EOF

echo "[+] Running depmod.pl"
$DEPMOD -F $OUTPUT_DIR/boot/boot/System.map-$BONE_KERNEL -b $INITRD_OUTPUT_TMPDIR/lib/modules > $INITRD_OUTPUT_TMPDIR/lib/modules/$BONE_KERNEL/modules.dep

echo "[+] Repacking initrd"
pack_initrd $INITRD_OUTPUT_TMPDIR $OUTPUT_DIR/boot/boot/initrd.img-$BONE_KERNEL

echo "-------------------- ROOTFS --------------------"
echo "[+] Copying rootfs"
cp -ra $PICORE_BASE_MNT/rootfs/tce $OUTPUT_DIR/rootfs/

echo "[+] Unpacking mydata.tgz"
[ -d $MYDATA_TMPDIR ] && rm -rf $MYDATA_TMPDIR
mkdir -p $MYDATA_TMPDIR
tar xf $OUTPUT_DIR/rootfs/tce/mydata.tgz -C $MYDATA_TMPDIR

echo "[+] Modifying mydata.tgz/opt/bootlocal.sh"
cat << "EOF" > $MYDATA_TMPDIR/opt/bootlocal.sh
#!/bin/sh
# put other system startup commands here

/usr/sbin/startserialtty &

GREEN="$(echo -e '\033[1;32m')"

echo
echo "${GREEN}Running bootlocal.sh..."
/home/tc/www/cgi-bin/do_rebootstuff.sh | tee -a /var/log/pcp_boot.log
EOF

echo "[+] Repacking mydata.tgz"
tar czf $OUTPUT_DIR/rootfs/tce/mydata.tgz .

echo "------------------ TC MODULES ------------------"
echo "[+] Creating alsa-modules-$BONE_KERNEL.tcz"
create_alsa_modules_tcz $BONE_BASE_MNT/rootfs/lib/modules/$BONE_KERNEL $OUTPUT_DIR/tcz

echo "[+] Creating wireless-$BONE_KERNEL.tcz"
create_wireless_tcz $BONE_BASE_MNT/rootfs/lib/modules/$BONE_KERNEL $OUTPUT_DIR/tcz

echo "[+] Copying alsa-modules and wireless tcz into mydata.tgz"
cp -ra $OUTPUT_DIR/tcz/alsa-modules-$BONE_KERNEL.* $OUTPUT_DIR/rootfs/tce/optional/
cp -ra $OUTPUT_DIR/tcz/wireless-$BONE_KERNEL.* $OUTPUT_DIR/rootfs/tce/optional/

echo "------------------ FINAL IMAGE -----------------"
echo "[+] Copying skeleton image and ungzipping it..."
cp $IMG_SKELETON $OUTPUT_IMAGE.gz
[ -f $OUTPUT_IMAGE ] && rm $OUTPUT_IMAGE
gunzip $OUTPUT_IMAGE.gz

echo "[+] Mounting output image..."
mount_image_partition $OUTPUT_IMAGE $OUTPUT_BASE_MNT/boot 1
mount_image_partition $OUTPUT_IMAGE $OUTPUT_BASE_MNT/rootfs 2

echo "[+] Copying filesystem over to final image"
cp -ra $OUTPUT_DIR/boot/* $OUTPUT_BASE_MNT/boot
cp -ra $OUTPUT_DIR/rootfs/* $OUTPUT_BASE_MNT/rootfs

echo "[+] Unmounting everything ... now that we are done..."
unmount_all
exit 0