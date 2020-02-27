#!/bin/bash
# Copyright (c) 2012 Tom Wambold
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This script will set up an Arch installation with a 100 MB /boot partition
# and an encrypted LVM partition with swap and / inside.  It also installs
# and configures systemd as the init system (removing sysvinit).
#
# You should read through this script before running it in case you want to
# make any modifications, in particular, the variables just below, and the
# following functions:
#
#    partition_drive - Customize to change partition sizes (/boot vs LVM)
#    setup_lvm - Customize for partitions inside LVM
#    install_packages - Customize packages installed in base system
#                       (desktop environment, etc.)

## CONFIGURE THESE VARIABLES
## ALSO LOOK AT THE install_packages FUNCTION TO SEE WHAT IS ACTUALLY INSTALLED

# Drive to install to.
DRIVE='/dev/nvme0n1'
BOOT_DEV="${DRIVE}p1" # Should be appended with just '1' for /dev/sd*
LVM_DEV="${DRIVE}p2"  # and 'p[1|2]' for /dev/nvme0n1

# Hostname of the installed machine.
HOSTNAME='computer'

# Encrypt everything (except /boot).  Leave blank to disable.
ENCRYPT_DRIVE='TRUE'

# Passphrase used to encrypt the drive (leave blank to be prompted).
DRIVE_PASSPHRASE=''

# Root password (leave blank to be prompted).
ROOT_PASSWORD=''

# Main user to create (by default, added to wheel group, and others).
USER_NAME='user'

# The main user's password (leave blank to be prompted).
USER_PASSWORD=''

# System timezone.
TIMEZONE='America/New_York'

# Have /tmp on a tmpfs or not.  Leave blank to disable.
# Only leave this blank on systems with very little RAM.
TMP_ON_TMPFS='TRUE'

#KEYMAP='us'
KEYMAP='dvorak'

# Choose your video driver
# For Intel
VIDEO_DRIVER="i915"
# For nVidia
#VIDEO_DRIVER="nouveau"
# For ATI
#VIDEO_DRIVER="radeon"
# For generic stuff
#VIDEO_DRIVER="vesa"

setup() {

    echo 'Creating partitions'
    partition_drive "$DRIVE"

    if [ -n "$ENCRYPT_DRIVE" ]
    then
        local lvm_part="/dev/mapper/lvm"

        if [ -z "$DRIVE_PASSPHRASE" ]
        then
            echo 'Enter a passphrase to encrypt the disk:'
            stty -echo
            read DRIVE_PASSPHRASE
            stty echo
        fi

        echo 'Encrypting partition'
        encrypt_drive "$DRIVE_PASSPHRASE" lvm

    else
        local lvm_part="$LVM_DEV"
    fi

    echo 'Setting up LVM'
    setup_lvm "$lvm_part" vg00

    echo 'Formatting filesystems'
    format_filesystems

    echo 'Mounting filesystems'
    mount_filesystems

    echo 'Installing base system'
    install_base

    echo 'Chrooting into installed system to continue setup...'
    cp $0 /mnt/setup.sh
    arch-chroot /mnt ./setup.sh chroot

    if [ -f /mnt/setup.sh ]
    then
        echo 'ERROR: Something failed inside the chroot, not unmounting filesystems so you can investigate.'
        echo 'Make sure you unmount everything before you try to run this script again.'
    else
        echo 'Unmounting filesystems'
        unmount_filesystems
        echo 'Done! Reboot system.'
    fi
}

configure() {

    echo 'Installing additional packages'
    install_packages

    echo 'Clearing package tarballs'
    clean_packages

    echo 'Updating pkgfile database'
    update_pkgfile

    echo 'Setting hostname'
    set_hostname "$HOSTNAME"

    echo 'Setting timezone'
    set_timezone "$TIMEZONE"

    echo 'Setting locale'
    set_locale

    echo 'Setting console keymap'
    set_keymap

    echo 'Setting hosts file'
    set_hosts "$HOSTNAME"

    echo 'Setting fstab'
    set_fstab "$TMP_ON_TMPFS"

    echo 'Setting initial modules to load'
    set_modules_load

    echo 'Configuring initial ramdisk'
    set_initcpio

    echo 'Setting initial daemons'
    set_daemons "$TMP_ON_TMPFS"

    echo 'Configuring bootloader'
    set_syslinux

    echo 'Configuring sudo'
    set_sudoers

    if [ -z "$ROOT_PASSWORD" ]
    then
        echo 'Enter the root password:'
        stty -echo
        read ROOT_PASSWORD
        stty echo
    fi
    echo 'Setting root password'
    set_root_password "$ROOT_PASSWORD"

    if [ -z "$USER_PASSWORD" ]
    then
        echo "Enter the password for user $USER_NAME"
        stty -echo
        read USER_PASSWORD
        stty echo
    fi
    echo 'Creating initial user'
    create_user "$USER_NAME" "$USER_PASSWORD"

    echo 'Building locate database'
    update_locate

    rm /setup.sh
}

partition_drive() {
    local dev="$1"; shift

    # 100 MB /boot partition, everything else under LVM
    parted -s "$dev" \
        mklabel msdos \
        mkpart primary ext2 1 100M \
        mkpart primary ext2 100M 100% \
        set 1 boot on \
        set 2 LVM on
}

encrypt_drive() {
    local passphrase="$1"; shift
    local name="$1"; shift

#    LVM_UUID=$(get_uuid "$LVM_DEV")
#    if [ -z "${LVM_UUID}" ]
#    then
#        echo "ERROR: LVM UUID not returned"
#        exit -1
#    fi

    echo -en "$passphrase" | cryptsetup -c aes-xts-plain -y -s 512 luksFormat "$LVM_DEV"
    echo -en "$passphrase" | cryptsetup luksOpen "$LVM_DEV" lvm
}

setup_lvm() {
    local partition="$1"; shift
    local volgroup="$1"; shift

    pvcreate "$partition"
    vgcreate "$volgroup" "$partition"

    # Create a 1GB swap partition
    lvcreate -C y -L1G "$volgroup" -n swap

    # Use the rest of the space for root
    lvcreate -l '+100%FREE' "$volgroup" -n root

    # Enable the new volumes
    vgchange -ay
}

format_filesystems() {
    mkfs.ext2 -L boot "${BOOT_DEV}"
    mkfs.ext4 -L root /dev/vg00/root
    mkswap /dev/vg00/swap
}

mount_filesystems() {
    mount /dev/vg00/root /mnt
    mkdir /mnt/boot
    mount "${BOOT_DEV}" /mnt/boot
    swapon /dev/vg00/swap
}

install_base() {
    echo 'Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist

    pacstrap /mnt base base-devel
    pacstrap /mnt syslinux
}

unmount_filesystems() {
    umount /mnt/boot
    umount /mnt
    swapoff /dev/vg00/swap
    vgchange -an
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        cryptsetup luksClose lvm
    fi
}

install_packages() {
    local packages=''

    # General utilities/libraries
    packages+=' linux linux-firmware lvm2 mkinitcpio cronie vim alsa-utils aspell-en cpupower mlocate iproute2 ntp openssh p7zip pkgfile powertop python python2 rfkill rsync sudo unrar unzip wget zip systemd-sysvcompat zsh grml-zsh-config git nano'

    # Network Manager
    packages+=' networkmanager nm-connection-editor network-manager-applet'

    # Xserver
    packages+=' xorg-apps xorg-server xorg-xinit xterm'

    # Fonts
    packages+=' ttf-dejavu ttf-liberation'

    # On Intel processors
    packages+=' intel-ucode'

    # For laptops
    packages+=' xf86-input-libinput'

    # Extra packages for tc4200 tablet
    #packages+=' ipw2200-fw xf86-input-wacom'

    if [ "$VIDEO_DRIVER" = "i915" ]
    then
        packages+=' xf86-video-intel libva-intel-driver'
    elif [ "$VIDEO_DRIVER" = "nouveau" ]
    then
        packages+=' xf86-video-nouveau'
    elif [ "$VIDEO_DRIVER" = "radeon" ]
    then
        packages+=' xf86-video-ati'
    elif [ "$VIDEO_DRIVER" = "vesa" ]
    then
        packages+=' xf86-video-vesa'
    fi

    pacman -Sy --noconfirm $packages
}

clean_packages() {
    yes | pacman -Scc
}

update_pkgfile() {
    pkgfile -u
}

set_hostname() {
    local hostname="$1"; shift

    echo "$hostname" > /etc/hostname
}

set_timezone() {
    local timezone="$1"; shift

    ln -sT "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
}

set_locale() {
    echo 'LANG="en_US.UTF-8"' >> /etc/locale.conf
    echo 'LC_COLLATE="C"' >> /etc/locale.conf
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
}

set_keymap() {
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

set_hosts() {
    local hostname="$1"; shift

    cat > /etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost $hostname
::1       localhost.localdomain localhost $hostname
EOF
}

set_fstab() {
    local tmp_on_tmpfs="$1"; shift

    local boot_uuid=$(get_uuid "${BOOT_DEV}")

    cat > /etc/fstab <<EOF
#
# /etc/fstab: static file system information
#
# <file system> <dir>    <type> <options>    <dump> <pass>

/dev/vg00/swap none swap  sw                0 0
/dev/vg00/root /    ext4  defaults,relatime 0 1

UUID=$boot_uuid /boot ext2 defaults,relatime 0 2
EOF
}

set_modules_load() {
    echo 'microcode' > /etc/modules-load.d/intel-ucode.conf
}

set_initcpio() {
    local vid

    if [ "$VIDEO_DRIVER" = "i915" ]
    then
        vid='i915'
    elif [ "$VIDEO_DRIVER" = "nouveau" ]
    then
        vid='nouveau'
    elif [ "$VIDEO_DRIVER" = "radeon" ]
    then
        vid='radeon'
    fi

    local encrypt=""
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        encrypt="encrypt"
    fi


    # Set MODULES with your video driver
    cat > /etc/mkinitcpio.conf <<EOF
# vim:set ft=sh
# MODULES
# The following modules are loaded before any boot hooks are
# run.  Advanced users may wish to specify all system modules
# in this array.  For instance:
#     MODULES="piix ide_disk reiserfs"
MODULES="ext4 $vid"

# BINARIES
# This setting includes any additional binaries a given user may
# wish into the CPIO image.  This is run last, so it may be used to
# override the actual binaries included by a given hook
# BINARIES are dependency parsed, so you may safely ignore libraries
BINARIES=""

# FILES
# This setting is similar to BINARIES above, however, files are added
# as-is and are not parsed in any way.  This is useful for config files.
# Some users may wish to include modprobe.conf for custom module options
# like so:
#    FILES="/etc/modprobe.d/modprobe.conf"
FILES=""

# HOOKS
# This is the most important setting in this file.  The HOOKS control the
# modules and scripts added to the image, and what happens at boot time.
# Order is important, and it is recommended that you do not change the
# order in which HOOKS are added.  Run 'mkinitcpio -H <hook name>' for
# help on a given hook.
# 'base' is _required_ unless you know precisely what you are doing.
# 'udev' is _required_ in order to automatically load modules
# 'filesystems' is _required_ unless you specify your fs modules in MODULES
# Examples:
##   This setup specifies all modules in the MODULES setting above.
##   No raid, lvm2, or encrypted root is needed.
#    HOOKS="base"
#
##   This setup will autodetect all modules for your system and should
##   work as a sane default
#    HOOKS="base udev autodetect pata scsi sata filesystems"
#
##   This is identical to the above, except the old ide subsystem is
##   used for IDE devices instead of the new pata subsystem.
#    HOOKS="base udev autodetect ide scsi sata filesystems"
#
##   This setup will generate a 'full' image which supports most systems.
##   No autodetection is done.
#    HOOKS="base udev pata scsi sata usb filesystems"
#
##   This setup assembles a pata mdadm array with an encrypted root FS.
##   Note: See 'mkinitcpio -H mdadm' for more information on raid devices.
#    HOOKS="base udev pata mdadm encrypt filesystems"
#
##   This setup loads an lvm2 volume group on a usb device.
#    HOOKS="base udev usb lvm2 filesystems"
#
##   NOTE: If you have /usr on a separate partition, you MUST include the
#    usr, fsck and shutdown hooks.
HOOKS="base udev autodetect modconf block keymap keyboard $encrypt lvm2 resume filesystems fsck"

# COMPRESSION
# Use this to compress the initramfs image. By default, gzip compression
# is used. Use 'cat' to create an uncompressed image.
#COMPRESSION="gzip"
#COMPRESSION="bzip2"
#COMPRESSION="lzma"
#COMPRESSION="xz"
#COMPRESSION="lzop"

# COMPRESSION_OPTIONS
# Additional options for the compressor
#COMPRESSION_OPTIONS=""
EOF

    mkinitcpio -p linux
}

set_daemons() {
    local tmp_on_tmpfs="$1"; shift

    systemctl enable cronie.service cpupower.service ntpd.service NetworkManager

    if [ -z "$tmp_on_tmpfs" ]
    then
        systemctl mask tmp.mount
    fi
}

set_syslinux() {

    local lvm_uuid=$(get_uuid "$LVM_DEV")

    local crypt=""
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        # Load in resources

        if [ -z "${lvm_uuid}" ]
        then
            echo "ERROR: LVM UUID not set"
            exit -1
        fi

        crypt="cryptdevice=/dev/disk/by-uuid/${lvm_uuid}:lvm"
    fi

    cat > /boot/syslinux/syslinux.cfg <<EOF
# Config file for Syslinux -
# /boot/syslinux/syslinux.cfg
#
# Comboot modules:
#   * menu.c32 - provides a text menu
#   * vesamenu.c32 - provides a graphical menu
#   * chain.c32 - chainload MBRs, partition boot sectors, Windows bootloaders
#   * hdt.c32 - hardware detection tool
#   * reboot.c32 - reboots the system
#   * poweroff.com - shutdown the system
#
# To Use: Copy the respective files from /usr/lib/syslinux to /boot/syslinux.
# If /usr and /boot are on the same file system, symlink the files instead
# of copying them.
#
# If you do not use a menu, a 'boot:' prompt will be shown and the system
# will boot automatically after 5 seconds.
#
# Please review the wiki: https://wiki.archlinux.org/index.php/Syslinux
# The wiki provides further configuration examples

DEFAULT arch
PROMPT 0        # Set to 1 if you always want to display the boot: prompt
TIMEOUT 50
# You can create syslinux keymaps with the keytab-lilo tool
#KBDMAP de.ktl

# Menu Configuration
# Either menu.c32 or vesamenu32.c32 must be copied to /boot/syslinux
UI menu.c32
#UI vesamenu.c32

# Refer to http://syslinux.zytor.com/wiki/index.php/Doc/menu
MENU TITLE Arch Linux
#MENU BACKGROUND splash.png
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

# boot sections follow
#
# TIP: If you want a 1024x768 framebuffer, add "vga=773" to your kernel line.
#
#-*

LABEL arch
	MENU LABEL Arch Linux
	LINUX ../vmlinuz-linux
	APPEND root=/dev/vg00/root ro $crypt resume=/dev/vg00/swap
	INITRD ../initramfs-linux.img

LABEL archfallback
	MENU LABEL Arch Linux Fallback
	LINUX ../vmlinuz-linux
	APPEND root=/dev/vg00/root ro $crypt resume=/dev/vg00/swap
	INITRD ../initramfs-linux-fallback.img

LABEL hdt
        MENU LABEL HDT (Hardware Detection Tool)
        COM32 hdt.c32

LABEL reboot
        MENU LABEL Reboot
        COM32 reboot.c32

LABEL off
        MENU LABEL Power Off
        COMBOOT poweroff.com
EOF

    syslinux-install_update -iam
}

set_sudoers() {
    cat > /etc/sudoers <<EOF
## sudoers file.
##
## This file MUST be edited with the 'visudo' command as root.
## Failure to use 'visudo' may result in syntax or file permission errors
## that prevent sudo from running.
##
## See the sudoers man page for the details on how to write a sudoers file.
##

##
## Host alias specification
##
## Groups of machines. These may include host names (optionally with wildcards),
## IP addresses, network numbers or netgroups.
# Host_Alias	WEBSERVERS = www1, www2, www3

##
## User alias specification
##
## Groups of users.  These may consist of user names, uids, Unix groups,
## or netgroups.
# User_Alias	ADMINS = millert, dowdy, mikef

##
## Cmnd alias specification
##
## Groups of commands.  Often used to group related commands together.
# Cmnd_Alias	PROCESSES = /usr/bin/nice, /bin/kill, /usr/bin/renice, \
# 			    /usr/bin/pkill, /usr/bin/top

##
## Defaults specification
##
## You may wish to keep some of the following environment variables
## when running commands via sudo.
##
## Locale settings
# Defaults env_keep += "LANG LANGUAGE LINGUAS LC_* _XKB_CHARSET"
##
## Run X applications through sudo; HOME is used to find the
## .Xauthority file.  Note that other programs use HOME to find
## configuration files and this may lead to privilege escalation!
# Defaults env_keep += "HOME"
##
## X11 resource path settings
# Defaults env_keep += "XAPPLRESDIR XFILESEARCHPATH XUSERFILESEARCHPATH"
##
## Desktop path settings
# Defaults env_keep += "QTDIR KDEDIR"
##
## Allow sudo-run commands to inherit the callers' ConsoleKit session
# Defaults env_keep += "XDG_SESSION_COOKIE"
##
## Uncomment to enable special input methods.  Care should be taken as
## this may allow users to subvert the command being run via sudo.
# Defaults env_keep += "XMODIFIERS GTK_IM_MODULE QT_IM_MODULE QT_IM_SWITCHER"
##
## Uncomment to enable logging of a command's output, except for
## sudoreplay and reboot.  Use sudoreplay to play back logged sessions.
# Defaults log_output
# Defaults!/usr/bin/sudoreplay !log_output
# Defaults!/usr/local/bin/sudoreplay !log_output
# Defaults!/sbin/reboot !log_output

##
## Runas alias specification
##

##
## User privilege specification
##
root ALL=(ALL) ALL

## Uncomment to allow members of group wheel to execute any command
# wheel ALL=(ALL) ALL

## Same thing without a password
%wheel ALL=(ALL) NOPASSWD: ALL

## Uncomment to allow members of group sudo to execute any command
# %sudo ALL=(ALL) ALL

## Uncomment to allow any user to run sudo if they know the password
## of the user they are running the command as (root by default).
# Defaults targetpw  # Ask for the password of the target user
# ALL ALL=(ALL) ALL  # WARNING: only use this together with 'Defaults targetpw'

%rfkill ALL=(ALL) NOPASSWD: /usr/sbin/rfkill
%network ALL=(ALL) NOPASSWD: /usr/bin/netcfg, /usr/bin/wifi-menu

## Read drop-in files from /etc/sudoers.d
## (the '#' here does not indicate a comment)
#includedir /etc/sudoers.d
EOF

    chmod 440 /etc/sudoers
}

set_root_password() {
    local password="$1"; shift

    echo -en "$password\n$password" | passwd
}

create_user() {
    local name="$1"; shift
    local password="$1"; shift

    useradd -m -s /bin/zsh -G adm,systemd-journal,wheel,rfkill,games,network,video,audio,optical,floppy,storage,scanner,power "$name"
    echo -en "$password\n$password" | passwd "$name"
}

update_locate() {
    updatedb
}

get_uuid() {
    if [ -z "$1" ]
    then
        echo "Expected parameter to get_uuid()"
        exit -1
    fi

    blkid -o export "$1" | grep '^UUID=' | awk -F= '{print $2}'

#    lsblk -n -o UUID "$1"
}

set -ex

if [ "$1" == "chroot" ]
then
    configure
else
    setup
fi
