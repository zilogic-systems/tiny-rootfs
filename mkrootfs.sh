#!/bin/bash

set -e

#
# Default User configuration
#
hostname=pixie
cross_prefix=arm-none-linux-gnueabi-
dl_dir=/tmp/dl
busybox_version=1.25.0
build_threads=4
console_dev=ttyS0
console_baud=115200
build_dir=build-${hostname}
img_filename=$PWD/${hostname}-ramdisk.img

function before_pack() {
    # Any commands to execute before packing up
    return
}

#
# Load Custom User Configuration
#

if [ -n "$1" ]; then
    source $1
fi

#
# Dev configuration
#

build_dir=$(realpath ${build_dir})
busybox_dirname=busybox-${busybox_version}
busybox_filename=${busybox_dirname}.tar.bz2
busybox_url='https://busybox.net/downloads/busybox-1.25.0.tar.bz2'
rootfs_dir=${build_dir}/rootfs
logfile=${build_dir}/log.txt

#
# Build Script
#

rm -fr ${build_dir}
mkdir -p ${build_dir}

echo "Build started on $(date)" > ${logfile}

echo "Downloading busybox ..."
mkdir -p ${dl_dir}
wget -c -O ${dl_dir}/${busybox_filename} ${busybox_url} >> ${logfile} 2>&1

echo "Extracting busybox ..."

pushd ${build_dir} >> ${logfile}
tar -x -f ${dl_dir}/${busybox_filename}
pushd ${busybox_dirname} >> ${logfile}

echo "Configuring busybox ..."

make defconfig >> ${logfile}
sed -i -e "s/^.*CONFIG_STATIC.*$/CONFIG_STATIC=y/" .config
sed -i -e "s/^.*CONFIG_UDHCPC6.*$/CONFIG_UDHCPC6=y/" .config
make oldconfig >> ${logfile}

echo "Building busybox ..."

make -j${build_threads} CROSS_COMPILE=${cross_prefix} >> ${logfile} 2>&1
make install CROSS_COMPILE=${cross_prefix} >> ${logfile} 2>&1
popd >> ${logfile}

mkdir -p ${rootfs_dir}
cp -a ${build_dir}/${busybox_dirname}/_install/* ${rootfs_dir}

echo "Setting up rootfs ..."

mkdir -p ${rootfs_dir}/dev ${rootfs_dir}/etc ${rootfs_dir}/var/log/
mkdir -p ${rootfs_dir}/proc ${rootfs_dir}/sys ${rootfs_dir}/tmp ${rootfs_dir}/root

cat > ${rootfs_dir}/etc/fstab <<EOF
proc  /proc proc  defaults  0 0
none  /tmp  tmpfs defaults  0 0
none  /root tmpfs defaults  0 0
sysfs /sys  sysfs defaults  0 0
EOF

cat > ${rootfs_dir}/etc/inittab <<EOF
::sysinit:/etc/init.d/rcS
${console_dev}::respawn:/sbin/getty -l /bin/sh -n ${console_baud} ${console_dev}
EOF

mkdir -p ${rootfs_dir}/etc/init.d
cat > ${rootfs_dir}/etc/init.d/rcS <<EOF
#!/bin/sh

mount /sys
mount /proc

echo /sbin/mdev > /proc/sys/kernel/hotplug

# Retrigger uevents to autoload modules
echo "Start uevents retrigger"
find -L /sys/bus -maxdepth 4 -name uevent -path "*/devices/*" -exec sh -c 'echo add > "{}"' ';'
echo "Done uevents retrigger"

/bin/mount -a
/bin/hostname ${hostname}

/sbin/syslogd -C
/sbin/klogd
EOF
chmod +x ${rootfs_dir}/etc/init.d/rcS

cat > ${rootfs_dir}/etc/mdev.conf <<'EOF'
$MODALIAS=.* 0:0 660 @modprobe -b "$MODALIAS"
EOF

echo "Running user customization ..."

before_pack ${rootfs_dir}

echo "Packing rootfs ..."

for size in 4096 8192 12288 16384 20480 24576 32768 65536 524288
do
    echo "Trying ${size}K" >> ${logfile}
    genext2fs -B 1024 -b ${size} -U -d ${rootfs_dir} ramdisk.ext2 && break
done

gzip --stdout ramdisk.ext2 > ${img_filename}
popd >> ${logfile}

echo "Build completed!"
