# Copyright 2023-2024 Broadcom. All rights reserved.
# SPDX-License-Identifier: BSD-2

# Red Hat Enterprise Linux Server 9

### Installs from the first attached CD-ROM/DVD on the system.
cdrom

### Performs the kickstart installation in text mode.
### By default, kickstart installations are performed in graphical mode.
text

#repo --name="AppStream" --baseurl=file:///run/install/sources/mount-0000-cdrom/AppStream
#repo --name="AppStream" --baseurl=https://pulp.example.com/pulp/content/image-automation/Production/cv_Base_Rhel9_with_Crowdstrike/content/dist/rhel9/$releasever/x86_64/appstream/os

%packages
@^server-product-environment
@performance
kexec-tools

%end

# Run the Setup Agent on first boot
firstboot --enable

### Accepts the End User License Agreement.
eula --agreed

### Sets the language to use during installation and the default language to use on the installed system.
lang ${vm_guest_os_language}

### Sets the default keyboard type for the system.
keyboard ${vm_guest_os_keyboard}

### Sets how the boot loader should be installed.
bootloader --location=mbr

### Initialize any invalid partition tables found on disks.
zerombr

ignoredisk --only-use=sda
### autopart
clearpart --none --initlabel
### Disk partitioning information
part pv.286 --fstype="lvmpv" --ondisk=sda --size=80294
part /boot --fstype="xfs" --ondisk=sda --size=1024
part /boot/efi --fstype="efi" --ondisk=sda --size=600 --fsoptions="umask=0077,shortname=winnt"
volgroup rhel --pesize=4096 pv.286
logvol / --fstype="xfs" --grow --size=1024 --name=root --vgname=rhel
logvol swap --fstype="swap" --size=4018 --name=swap --vgname=rhel
logvol /home --fstype="xfs" --grow --size=500 --name=home --vgname=rhel

### Partitioning
### ${storage}

### Configure network information for target system and activate network devices in the installer environment (optional)
### --onboot	  enable device at a boot time
### --device	  device to be activated and / or configured with the network command
### --bootproto	  method to obtain networking configuration for device (default dhcp)
### --noipv6	  disable IPv6 on this device
${network}

### Lock the root account.
# Root password
###rootpw --iscrypted $6$j1gglZfbSx3pvsXb$/.l0O2E0aPt4H7.lXaWoub9RYt/ZjeEfY.kaEFzgeEMBP6i9K1CA9B5Ep7B5LfMnSY2.GP/F31633sr85YfsG1
rootpw --iscrypted $6$clQfWxEDlaoQxQ4M$1XTdUIx9eBreGybUlbRL4kE.Z4Z2hYeJ52RGRZsBXWHvJs99B2xq6vXa.6Y8joC6HEeprohCjaQ7lTtTdneM10

### The selected profile will restrict root login.
### Add users that can login and escalate privileges.
user --groups=wheel --name=buildops --password=$6$wLXrHF8T0YquOcND$bwjjgjlNuMy/TTqwsY5mPSSxi9Imz4tF3BnFUWJVq50gxX6AGD2YZFM45tpcmFvtpaav7YJvsxrFbHqsryfAf. --iscrypted --gecos="buildops"
user --groups=wheel --name=buildops --password=$6$dYVE4rlyJcaS/rRV$tmJUyo/BffY6XmpuPl6yLH9DAyH7PdCNSa2DqmdBa9LVgvFM6Qaamqo/RW2EbZKT6ujVXNdnQkxlEYAKs/uFO. --iscrypted --gecos="buildops"
user --groups=wheel --name=vrautomation --password=$6$MHner2XxQVMaoLhw$E3WcxTEi7FSxRs/Dmq6CdHTFHFWNGEOJ80PvkvT3451eRlfOo08EjPgrap4Ng0aNfsjHNyAmxE64X4Ciq3W1p1 --iscrypted --gecos="vrautomation"

### Configure firewall settings for the system.
### --enabled	reject incoming connections that are not in response to outbound requests
### --ssh		allow sshd service through the firewall
firewall --enabled --ssh

### Sets up the authentication options for the system.
### The SSDD profile sets sha512 to hash passwords. Passwords are shadowed by default
### See the manual page for authselect-profile for a complete list of possible options.
authselect select sssd

### Sets the state of SELinux on the installed system.
### Defaults to enforcing.
### selinux --enforcing
selinux --permissive

### Sets the system time zone.
timezone ${vm_guest_os_timezone}

### Partitioning
### VM Storage Settings

### Modifies the default set of services that will run under the default runlevel.
services --enabled=NetworkManager,sshd

### Do not configure X on the installed system.
skipx

### Packages selection.
%packages --ignoremissing --excludedocs
@core
-iwl*firmware
%end

%addon com_redhat_kdump --enable --reserve-mb='auto'

%end

%anaconda
pwpolicy root --minlen=6 --minquality=1 --notstrict --nochanges --notempty
pwpolicy user --minlen=6 --minquality=1 --notstrict --nochanges --emptyok
pwpolicy luks --minlen=6 --minquality=1 --notstrict --nochanges --notempty
%end

### Post-installation commands.
%post
### /usr/sbin/subscription-manager register --username ${rhsm_username} --password ${rhsm_password} --autosubscribe --force
/usr/sbin/subscription-manager register --org="image-automation" --activationkey="AK_EXAMPLE_Rhel9" --force
/usr/sbin/subscription-manager refresh
/usr/sbin/subscription-manager repos --enable "*"

### Update and Upgrade the system
### dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
dnf makecache
dnf update -y
dnf upgrade -y
dnf install -y sudo open-vm-tools perl

%{ if additional_packages != "" ~}
dnf install -y ${additional_packages}
%{ endif ~}

dnf install -y yum-utils
dnf install -y chkconfig
dnf install -y chrony

# Installing packages for sssd
dnf install -y samba-common-tools
dnf install -y realmd
dnf install -y oddjob
dnf install -y oddjob-mkhomedir
dnf install -y sssd
dnf install -y adcli
dnf install -y krb5-workstation

echo "buildops ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/buildops
echo "vrautomation ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/vrautomation
echo "buildops ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/buildops
echo "%wheel  ALL=(ALL) NOPASSWD: ALL >> /etc/sudoers.d/wheel
echo "%wheel  ALL=(ALL) NOPASSWD: ALL >> /etc/sudoers
sed -i "s/^.*requiretty/#Defaults requiretty/" /etc/sudoers
sed -i -e 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

# Modify GRUB to disable IPv6 at boot
grubby --update-kernel ALL --args="ipv6.disable=1"

# Disable IPv6 in the kernel
# Use sysctl to disable IPv6 for all interfaces
echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/60-disable_ipv6.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/60-disable_ipv6.conf

# Modify NetworkManager settings to not auto-create IPv6 connections
nmcli connection modify "VMware customization ens192" ipv6.method "disabled"
nmcli device status
nmcli connection show --active
sysctl -p /etc/sysctl.d/60-disable_ipv6.conf

# Rebuild grub.cfg for the change to take effect
grub2-mkconfig -o /boot/grub2/grub.cfg
%end

### Reboot after the installation is complete.
### --eject attempt to eject the media before rebooting.
reboot --eject
