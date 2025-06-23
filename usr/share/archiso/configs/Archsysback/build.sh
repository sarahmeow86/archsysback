#!/bin/bash

set -e -u
base_dir="/usr/share/archiso/configs/Archsysback"
iso_name=archsysback
iso_label="ARCHSYSBACK_$(date +%y%m)"
iso_version=$(date +%Y.%m.%d)
install_dir=arch
arch=$(uname -m)
work_dir=work
out_dir=out
kernels="$(ls /boot/vmlinuz* | sort)"
kernel= kernel=$(echo "${kernels##*$'\n'}" | cut -d "/" -f3-)

cd ${base_dir}
rm -rf work out

umask 0022

# Ensure /timeshift is a btrfs subvolume
make_timeshift_subvolume() {
    if ! btrfs subvolume list / | grep -q "timeshift"; then
        echo "Creating btrfs subvolume for /timeshift"
        btrfs subvolume create /timeshift
    else
        echo "/timeshift btrfs subvolume already exists"
    fi
}

# Mount the btrfs subvolume to /timeshift
mount_timeshift_subvolume() {
    mountpoint -q /timeshift && return
    rootdev=$(findmnt -n -o SOURCE /)
    mount -o subvol=timeshift $rootdev /timeshift
}

# Create timeshift config
make_timeshift_conf() {

# UUID of root partition
uuid=$(blkid | grep "$(mount | grep 'on / ' | cut -d ' ' -f 1)" | cut -d ' ' -f 3 | cut -d '"' -f 2 -)
# localized desktop name, need to backup desktop shortcuts
desktop_name=$(xdg-user-dir DESKTOP |cut -d "/" -f-2 --complement)
# default timeshift config
FILE=/etc/timeshift.json

cat <<EOF > "$FILE"
{
  "backup_device_uuid" : "$uuid",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "btrfs_use_qgroup" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly" : "false",
  "schedule_daily" : "false",
  "schedule_hourly" : "false",
  "schedule_boot" : "false",
  "count_monthly" : "2",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "6",
  "count_boot" : "5",
  "snapshot_size" : "60200542680",
  "snapshot_count" : "1172972",
  "exclude" : [
    "+ /root/.**",
    "+ /home/*/.**",
    "+ /home/*/conkystart",
    "+ /home/*/*/",
    "/usr/share/archiso/configs*/*/work/***",
    "/usr/share/archiso/configs*/*/out/***",
    "/var/cache/pacman/pkg/**",
    "+ /boot/amd-ucode.img",
    "+ /boot/intel-ucode.img",
    "+ /boot/memtest86+/memtest.bin",
    "+ /media/*/*/",
    "+ /home/*/$desktop_name/***",
    "+ /home/*/Desktop/***",
    "/home/*/**"
  ],
  "exclude-apps" : [
  ]
}
EOF
echo "$FILE created."


}

# make fresh timeshift backup(){
DIR=/timeshift
if [ ! -d $DIR ]; then
    mkdir -p $DIR
fi

# Full system backup with timeshift, delete old snapshots first
timeshift --delete-all
timeshift --create --scripted --snapshot-device "$(mount |grep "on / " |cut -d " " -f1)"


# Base installation (airootfs)
make_basefs() {
mkdir -p ${work_dir}

# Find the latest timeshift snapshot's localhost directory (btrfs mode)
cd "$(ls -d /timeshift/snapshots/*/localhost 2>/dev/null | sort | tail -n1)"

# Backup the original fstab as fstab.orig
mv etc/fstab etc/fstab.orig

# Create a new empty fstab
touch etc/fstab

# Copy timeshift settings to backup
cp /etc/timeshift.json etc/timeshift.json
cd ..
mv -f localhost ${base_dir}/${work_dir}/airootfs
cd ${base_dir}
}

# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
make_setup_mkinitcpio() {
    mkdir -p ${work_dir}/airootfs/etc/initcpio/hooks
    mkdir -p ${work_dir}/airootfs/etc/initcpio/install
    cp /usr/lib/initcpio/hooks/archiso ${work_dir}/airootfs/etc/initcpio/hooks
    cp /usr/lib/initcpio/install/archiso ${work_dir}/airootfs/etc/initcpio/install
    cp ${base_dir}/mkinitcpio-archiso.conf ${work_dir}/airootfs/etc/mkinitcpio-archiso.conf
    cp ${base_dir}/mkinitcpio.conf ${work_dir}/airootfs/etc/mkinitcpio.conf
    mkarchiso -v -w "${work_dir}" -D "${install_dir}" -r "mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/$kernel -g /boot/archiso.img" run
}

# Prepare ${install_dir}/boot/
make_boot() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/${arch}
    cp ${work_dir}/airootfs/boot/archiso.img ${work_dir}/iso/${install_dir}/boot/${arch}/archiso.img
    cp ${work_dir}/airootfs/boot/$kernel ${work_dir}/iso/${install_dir}/boot/${arch}/vmlinuz
}

# Add other aditional/extra files to ${install_dir}/boot/
make_boot_extra() {
    cp ${work_dir}/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
    cp ${work_dir}/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
    cp ${work_dir}/airootfs/boot/intel-ucode.img ${work_dir}/iso/${install_dir}/boot/intel_ucode.img
    cp ${work_dir}/airootfs/usr/share/licenses/intel-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/intel_ucode.LICENSE
    cp ${work_dir}/airootfs/boot/amd-ucode.img ${work_dir}/iso/${install_dir}/boot/amd_ucode.img
    cp ${work_dir}/airootfs/usr/share/licenses/amd-ucode/LICENSE ${work_dir}/iso/${install_dir}/boot/amd_ucode.LICENSE
}


# Prepare /${install_dir}/boot/syslinux
make_syslinux() {
    _uname_r=$(file -b ${work_dir}/airootfs/boot/$kernel | awk 'f{print;f=0} /version/{f=1}' RS=' ')
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux
    for _cfg in ${base_dir}/syslinux/*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
    done
    cp -L ${base_dir}/syslinux/splash.png ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
    gzip -c -9 ${work_dir}/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
    gzip -c -9 ${work_dir}/airootfs/usr/lib/modules/${_uname_r}/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz
}

# Prepare /isolinux
make_isolinux() {
    mkdir -p ${work_dir}/iso/isolinux
    sed "s|%INSTALL_DIR%|${install_dir}|g" ${base_dir}/isolinux/isolinux.cfg > ${work_dir}/iso/isolinux/isolinux.cfg
    cp ${work_dir}/airootfs/usr/lib/syslinux/bios/isolinux.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/airootfs/usr/lib/syslinux/bios/isohdpfx.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/airootfs/usr/lib/syslinux/bios/ldlinux.c32 ${work_dir}/iso/isolinux/
}


# Prepare /EFI
make_efi() {
    mkdir -p ${work_dir}/iso/EFI/boot ${work_dir}/iso/EFI/live
    cp ${work_dir}/airootfs/usr/share/refind/refind_x64.efi ${work_dir}/iso/EFI/boot/bootx64.efi
    cp -a ${work_dir}/airootfs/usr/share/refind/{drivers_x64,icons}/ ${work_dir}/iso/EFI/boot/

    cp ${work_dir}/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/iso/EFI/live/livedisk.efi
    cp ${work_dir}/airootfs/usr/share/refind/icons/os_arch.png ${work_dir}/iso/EFI/live/livedisk.png

    cp -L ${base_dir}/efiboot/boot/refind-usb.conf ${work_dir}/iso/EFI/boot/refind.conf

    mkdir -p ${work_dir}/iso/loader/entries
    cp -L ${base_dir}/efiboot/loader/loader.conf ${work_dir}/iso/loader/
    cp -L ${base_dir}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/iso/loader/entries/
    cp -L ${base_dir}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/iso/loader/entries/
    cp ${base_dir}/efiboot/loader/entries/archiso-x86_64-usb.conf ${work_dir}/iso/loader/entries/archiso-x86_64.conf
    cp ${base_dir}/efiboot/loader/entries/archiso_console-x86_64-usb.conf ${work_dir}/iso/loader/entries/archiso_console-x86_64.conf
    cp ${base_dir}/efiboot/loader/entries/archiso_ram-x86_64-usb.conf ${work_dir}/iso/loader/entries/archiso_ram-x86_64.conf

    sed -i "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
        ${work_dir}/iso/loader/entries/archiso{,_console,_ram}-x86_64.conf

    # EFI Shell 2.0 for UEFI 2.3+
    curl -o ${work_dir}/iso/EFI/shellx64_v2.efi https://raw.githubusercontent.com/tianocore/edk2/UDK2018/ShellBinPkg/UefiShell/X64/Shell.efi
    # EFI Shell 1.0 for non UEFI 2.3+
    curl -o ${work_dir}/iso/EFI/shellx64_v1.efi https://raw.githubusercontent.com/tianocore/edk2/UDK2018/EdkShellBinPkg/FullShell/X64/Shell_Full.efi
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {
    mkdir -p ${work_dir}/iso/EFI/archiso
    truncate -s 64M ${work_dir}/iso/EFI/archiso/efiboot.img
    mkfs.fat -n LIVEMEDIUM ${work_dir}/iso/EFI/archiso/efiboot.img

    mkdir -p ${work_dir}/efiboot
    mount ${work_dir}/iso/EFI/archiso/efiboot.img ${work_dir}/efiboot

    mkdir -p ${work_dir}/efiboot/EFI/archiso
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz ${work_dir}/efiboot/EFI/archiso/vmlinuz.efi
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img ${work_dir}/efiboot/EFI/archiso/archiso.img

    cp ${work_dir}/iso/${install_dir}/boot/intel_ucode.img ${work_dir}/efiboot/EFI/archiso/intel_ucode.img
    cp ${work_dir}/iso/${install_dir}/boot/amd_ucode.img ${work_dir}/efiboot/EFI/archiso/amd_ucode.img

    mkdir -p ${work_dir}/efiboot/EFI/boot ${work_dir}/efiboot/EFI/live
    cp ${work_dir}/airootfs/usr/share/refind/refind_x64.efi ${work_dir}/efiboot/EFI/boot/bootx64.efi
    cp -a ${work_dir}/airootfs/usr/share/refind/{drivers_x64,icons}/ ${work_dir}/efiboot/EFI/boot/

    cp ${work_dir}/airootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi ${work_dir}/efiboot/EFI/live/livedvd.efi
    cp ${work_dir}/airootfs/usr/share/refind/icons/os_arch.png ${work_dir}/efiboot/EFI/live/livedvd.png

    cp -L ${base_dir}/efiboot/boot/refind-dvd.conf ${work_dir}/efiboot/EFI/boot/refind.conf

    mkdir -p ${work_dir}/efiboot/loader/entries
    cp -L ${base_dir}/efiboot/loader/loader.conf ${work_dir}/efiboot/loader/
    cp -L ${base_dir}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/efiboot/loader/entries/
    cp -L ${base_dir}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/efiboot/loader/entries/
    cp ${base_dir}/efiboot/loader/entries/archiso-x86_64-cd.conf ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf
    cp ${base_dir}/efiboot/loader/entries/archiso_console-x86_64-cd.conf ${work_dir}/efiboot/loader/entries/archiso_console-x86_64.conf
    cp ${base_dir}/efiboot/loader/entries/archiso_ram-x86_64-cd.conf ${work_dir}/efiboot/loader/entries/archiso_ram-x86_64.conf

    sed -i "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
        ${work_dir}/efiboot/loader/entries/archiso{,_console,_ram}-x86_64.conf

    cp ${work_dir}/iso/EFI/shellx64_v2.efi ${work_dir}/efiboot/EFI/
    cp ${work_dir}/iso/EFI/shellx64_v1.efi ${work_dir}/efiboot/EFI/

    umount -d ${work_dir}/efiboot
}

# Build airootfs filesystem image
make_prepare() {
    mkarchiso -v -w "${work_dir}" -D "${install_dir}" prepare
}

# Build ISO
make_iso() {
    mkarchiso -v -w "${work_dir}" -D "${install_dir}" -L "${iso_label}" -o "${out_dir}" iso "${iso_name}-${iso_version}-${arch}.iso"
}

make_timeshift_subvolume
mount_timeshift_subvolume
make_timeshift_conf
make_timeshift_backup
make_basefs
make_setup_mkinitcpio
make_boot
make_boot_extra
make_syslinux
make_isolinux
make_efi
make_efiboot
make_prepare
make_iso
make_efi
make_efiboot
make_prepare
make_iso
