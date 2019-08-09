#!/bin/bash

# Script to configure new Expedition VM after initial install:
#
# Before running:
# 
# * Update static IP configuration below.
#   * If DHCP is desired, comment/remove the variables.
# * Allocate appropriate RAM/CPUs/Disk space.
#	* Script assumes min 8GB, 4CPU, 40GB disk. 
#   * Script assumes existing disk is expanded rather than adding a new one.
#
# Notes:

# * Unattended updates will run, if it's not already in progress. Script will wait for it to complete.
# * The existing disk will be reconfigured to allow use of the expanded space.
#   * The partition table will be converted from MBR to GPT to allow drives >=2TB
#   * A GPT boot partition will be created and GRUB reinstalled so the box still boots afterwards.
#   * A new LVM PV will be created using the empty space on the drive
#   * The new partition will be added to the existing LVM VG.
#   * A new LVM volume will be created for log storage using 80% of free space in the VG.
#   * Remaining free space can be used to extend the root volume, create snapshots, etc. 

# Configuration options for static IP. Default is DHCP, uncomment and set if needed.

# IP=192.168.1.10
# MASK=255.255.255.0
# GW=192.168.1.254
# DNS=8.8.8.8

# can put in local file ip-config.local

[[ -f ip-config.local ]] && source ip-config.local

# End of configuration. Beyond here be janky code. And probably dragons.

# messaging functions

task-start () {
    [[ -z $taskName ]] || echo -e "\r$taskName: [Done]   "
    taskName=$1
    echo -n -e "\r$taskName: [...]"

}

task-end () {
    [[ -z $taskName ]] || echo -e "\r$taskName: [Done]   "
    unset taskName
}                     

task-wait () {

	while pgrep -f $1 &> /dev/null
	do
        echo -n -e "\r$taskName: [ - ] \r"
        sleep .25
        echo -n -e "\r$taskName: [ \\ ] \r"
        sleep .25
        echo -n -e "\r$taskName: [ | ] \r"
        sleep .25
        echo -n -e "\r$taskName: [ / ] \r"
        sleep .25
    done
	
    task-end
}

oh-bother () {
	echo -e "\n\nERROR: $1"
	exit 1
}

# Need to run as root
if [ "$(whoami)" != "root" ]
then
    sudo su -s "$0"
    exit
fi

# IP configuration
if [[ ! -z "$IP" ]]
then
    # Static configuration is present and needs to be applied
	echo "----------Using Static IP Configuration----------"
	task-start "Updating /etc/network/interfaces"
    sed -i "s/iface ens33 inet dhcp/iface ens33 inet static\\n address $IP\\n netmask $MASK\\n gateway $GW\\n dns-nameservers $DNS\\n/g" /etc/network/interfaces
	task-start "Clearing DHCP Config"
    ip addr flush ens33 &> /dev/null 
	task-start "Shutting down interface"
	ifdown ens33 &> /dev/null
	task-start "Activating interface"
	ifup ens33 &> /dev/null
	task-end
else
    # DHCP is the default. Print message and move on.
	echo "----------Using DHCP----------"
fi


# Initiate check for updates and wait for it to finish
echo "----------System Updates----------"
task-start "Unattended Upgrades"
pgrep -f unattended-upgrade &> /dev/null || unattended-upgrade & 

# unattended-upgrade calls another script; give it a chance to start before checking
sleep 5
task-wait unattended-upgrade

# Repartition the disk to add new storage volume. 
# We are converting to GPT to allow disk > 2TB
echo "----------Partitioning Disk----------"

# gdisk isn't installed by default as OVA was built using MBR
task-start "Installing gdisk"
apt-get -y install gdisk &> /dev/null || oh-bother "Could not install gdisk. Verify that the Internet is accessible and try again."

# Create partitions. Existing disk has partitions 1 and 5
# Add partition 2 in the first 1MB of the disk for GPT BIOS boot partition
# Add partition 3 using remaining free space on disk to extend the LVM VG
task-start "Converting partition table and adding new partitions"
sgdisk -g -n 2:34:2047 -n 3:0:0 -t 2:ef02 -t 3:8e00 /dev/sda &> /dev/null

# Reload partition table into kernel so we can access the new partitions
task-start "Reloading partition table"
partprobe &> /dev/null

# Need to re-install GRUB due to conversion to GPT
task-start "Installing GPT GRUB"
grub-install /dev/sda &> /dev/null
task-end

# Creating a new volume and directory for log storage
echo "----------Creating Storage Volume and Log Directory----------"

# Attaching the new partition to the existing VG. 
task-start "Adding new partition to LVM volume group Expedition-vg"
vgextend Expedition-vg /dev/sda3 &> /dev/null

# Use new free space in VG to create storage LV
task-start "Create new storage volume in volume group Expedition-vg"
lvcreate -l 80%FREE -n storage Expedition-vg &> /dev/null

# Format new volume with ext4 filesystem
task-start "Formatting volume with ext4"
mkfs -t ext4 /dev/mapper/Expedition--vg-storage &> /dev/null

# Creating new mount point /storage for the new volume.
# Mounting one level up to prevent giving www-data access to root of volume.
task-start "Create mount point and mount storage volume"
mkdir /storage
mount /dev/mapper/Expedition--vg-storage /storage

# Add the new volume to fstab for automatic mount on boot
task-start "Adding storage volume to fstab"
echo -e '\n/dev/mapper/Expedition--vg-storage /storage ext4 relatime,errors=remount-ro 0 1' >> /etc/fstab

# Create and configure paLogs and mlTmp directories within the new volume and assign permissions to www-data
task-start "Create paLogs and mlTmp directories and set permissions"
mkdir /storage/paLogs /storage/mlTmp
chown -R www-data:www-data /storage/paLogs /storage/mlTmp
task-end

# Updating the expedition packages to latest version
echo "----------Updating Expedition----------"

# patch expedition repository to be trusted
# avoids error during update and possible failure to update
task-start "Marking repository as trusted"
sed -i "s/deb http/deb [trusted=yes] http/g" /etc/apt/sources.list.d/ex-repo.list

# update apt package cache from repositories
task-start "Updating package database"
apt-get update &> /dev/null &
task-wait  "apt get update"

# install latest expedition packages
task-start "Installing package expedition-beta"
apt-get install expedition-beta &> /dev/null &
task-wait "apt-get"

task-start "Installing package expeditionml-dependencies-beta"
apt-get install expeditionml-dependencies-beta &> /dev/null &
task-wait "apt-get"

# cleaning up installation environment
task-start "Fixing any incomplete packages"
apt-get -y -f install &> /dev/null &
task-wait 'apt-get'

task-start "Removing any unneded packages"
apt-get -y autoremove &> /dev/null &
task-wait "apt-get"

# Restarting Apache to complete update of application. 
task-start "Restarting Apache"
systemctl restart apache2 &> /dev/null
task-end

# For security reasons, SSH/SSL keys should be replaced
echo "----------Regenerating keys----------"

# reset ssh host keys
task-start "Erasing old SSH keys"
rm /etc/ssh/ssh_host_* &> /dev/null
task-start "Generating new SSH keys"
dpkg-reconfigure openssh-server  &> /dev/null
task-start "Restarting sshd"
systemctl restart sshd &> /dev/null

# regenerate snakeoil cert
task-start "Regenerating self-signed certificate"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/ssl/certs/server.key -out /etc/ssl/certs/certificate.pem -subj '/CN=expedition' &> /dev/null
task-end

# Some of the parameters listed in the document were already patched in the OVA release. These weren't.

echo "----------Updating settings----------"

task-start "Update ML Settings in Expedition database"
mysql -u root -ppaloalto -D pandbRBAC -e 'UPDATE ml_settings SET server="localhost", parquetPath="/storage/paLogs", tempDataPath="/storage/mlTmp"'

# increase parser max memory
task-start "Expanding parser memory allocation to 3GB"
sed -i "s/\('PARSER_max_execution_memory','1G'\)/\('PARSER_max_execution_memory','3G'\)/g" /var/www/html/libs/common/userDefinitions.php

# Delete file; will be regenerated using correct values from the current environment.
task-start "Clearing CPU and memory parameter cache"
rm -f /home/userSpace/environmentParameters.php
task-end

# Done, prompt to reboot
echo -e "\n\n * Please reboot to finish setting up Expedition * \n\n"



