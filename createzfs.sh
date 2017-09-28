#!/bin/bash
################################################################################
# This is property of eXtremeSHOK.com
# You are free to use, modify and distribute, however you may not remove this notice.
# Copyright (c) Adrian Jon Kriel :: admin@extremeshok.com
################################################################################
#
# Script updates can be found at: https://github.com/extremeshok/xshok-proxmox
#
# Will create a ZFS pool from the devices specified with the correct raid level
#
# License: BSD (Berkeley Software Distribution)
#
################################################################################
#
# Creates the following storage/rpools
# poolnamebackup (poolname/backup)
# poolnamevmdata (poolname/vmdata)
#
# Will automatically detect the required raid level and optimise.
#
# 1 Drive = zfs
# 2 Drives = mirror
# 3-5 Drives = raidz-1
# 6-11 Drives = raidz-2
# 11+ Drives = raidz-3
#
# NOTE: WILL  DESTROY ALL DATA ON DEVICES SPECIFED
#
# Usage:
# curl -O https://raw.githubusercontent.com/extremeshok/xshok-proxmox/master/createzfs.sh && chmod +x createzfs.sh
# ./createzfs.sh poolname /dev/sda /dev/sdb
#
################################################################################
#
#    THERE ARE  USER CONFIGURABLE OPTIONS IN THIS SCRIPT
#   ALL CONFIGURATION OPTIONS ARE LOCATED BELOW THIS MESSAGE
#
##############################################################

poolname=${1}
zfsdevicearray=("${@:2}")

if ! type "zpool" 2> /dev/null; then
  echo "zfs is not avilable"
  exit 1
fi

#check arguments
if [ $# -lt "2" ] ; then
  echo "ERROR: missing aguments"
  echo "Usage: $(basename "$0") poolname /list/of /dev/devices"
  echo "Note will append 'pool' to the poolname, eg. hdd -> hddpool"
  exit 1
fi
if [[ "$poolname" =~ "/" ]] ; then
  echo "ERROR: invalid poolname: $poolname"
  exit 1
else
  #add the suffix pool to the poolname, prevent namepoolpool
  poolprefix=${poolname#pool}
  poolname="$poolprefix""pool"  
fi
if [ "${#zfsdevicearray[@]}" -lt "1" ] ; then
  echo "ERROR: less than 1 devices were detected"
  exit 1
fi
for zfsdevice in "${zfsdevicearray[@]}" ; do
  if ! [[ "${2}" =~ "/" ]] ; then
    echo "ERROR: Invalid device specified: $zfsdevice"
    exit 1
  fi
  if ! [ -e "$zfsdevice" ]; then
    echo "ERROR: Device $zfsdevice does not exist"
    exit 1
  fi
  if grep -q "$zfsdevice" "/proc/mounts" ; then
    echo "ERROR: Device is mounted $zfsdevice"
    exit 1
  fi
done

echo "Enabling ZFS"
systemctl enable zfs.target
systemctl start zfs.target
modprobe zfs

if [ "$(zpool import | grep -m 1 -o "\s$poolname\b")" == "$poolname" ] ; then
	echo "ERROR: $poolname already exists as an exported pool"
	zpool import
	exit 1
fi
if [ "$(zpool list | grep -m 1 -o "\s$poolname\b")" == "$poolname" ] ; then
	echo "ERROR: $poolname already exists as a listed pool"
	zpool list
	exit 1
fi

echo "Creating the array"
if [ "${#zfsdevicearray[@]}" -eq "1" ] ; then
  echo "Creating ZFS mirror (raid1)"
  zpool create -f -o ashift=12 -O compression=lz4 "$poolname" ${zfsdevicearray[@]}
  ret=$?
elif [ "${#zfsdevicearray[@]}" -eq "2" ] ; then
  echo "Creating ZFS mirror (raid1)"
  zpool create -f -o ashift=12 -O compression=lz4 "$poolname" mirror ${zfsdevicearray[@]}
  ret=$?
elif [ "${#zfsdevicearray[@]}" -ge "3" ] && [ "${#zfsdevicearray[@]}" -le "5" ] ; then
  echo "Creating ZFS raidz-1 (raid5)"
  zpool create -f -o ashift=12 -O compression=lz4 "$poolname" raidz ${zfsdevicearray[@]}
  ret=$?
elif [ "${#zfsdevicearray[@]}" -ge "6" ] && [ "${#zfsdevicearray[@]}" -lt "11" ] ; then
  echo "Creating ZFS raidz-2 (raid6)"
  zpool create -f -o ashift=12 -O compression=lz4 "$poolname" raidz2 ${zfsdevicearray[@]}
  ret=$?
elif [ "${#zfsdevicearray[@]}" -ge "11" ] ; then
  echo "Creating ZFS raidz-3 (raid7)"
  zpool create -f -o ashift=12 -O compression=lz4 "$poolname" raidz3 ${zfsdevicearray[@]}
  ret=$?
fi

if [ $ret != 0 ] ; then
	echo "ERROR: creating ZFS"
	exit 1
fi

if [ "$( zpool list | grep  "$poolname" | cut -f 1 -d " ")" != "$poolname" ] ; then
	echo "ERROR: $poolname pool not found"
	zpool list
	exit 1
fi

echo "Creating Secondary ZFS Pools"
zfs create -o mountpoint="/vmdata_""$poolprefix" "$poolname""/vmdata"
zfs create -o mountpoint="/backup_""$poolprefix" "$poolname""/backup"

if type "pvesm" 2> /dev/null; then
  echo "Adding the ZFS storage pools to Proxmox GUI"
  pvesm add dir "$poolname""backup" "/backup_""$poolprefix"
  pvesm add zfspool "$poolname""vmdata" -pool "$poolname""/vmdata" -sparse true
fi

echo "Setting ZFS Optimisations"
zfspoolarray=("$poolname" "$poolname""/vmdata" "$poolname""/backup")
for zfspool in "${zfspoolarray[@]}" ; do
  echo "Optimising $zfspool"
  zfs set compression=on "$zfspool"
  zfs set compression=lz4 "$zfspool"
  zfs set sync=disabled "$zfspool"
  zfs set primarycache=all "$zfspool"
  zfs set atime=off "$zfspool"
  zfs set checksum=off "$zfspool"
  zfs set dedup=off "$zfspool"
  
  echo "Adding weekly pool scrub for $zfspool"
  if [ ! -f "/etc/cron.weekly/$poolname" ] ; then
    echo '#!/bin/bash' > "/etc/cron.weekly/$poolname"
  fi  
  echo "zpool scrub $zfspool" >> "/etc/cron.weekly/$poolname"
done

### Work in progress , create specialised pools ###
# echo "ZFS 8GB swap partition"
# zfs create -V 8G -b $(getconf PAGESIZE) -o logbias=throughput -o sync=always -o primarycache=metadata -o com.sun:auto-snapshot=false "$poolname"/swap
# mkswap -f /dev/zvol/"$poolname"/swap
# swapon /dev/zvol/"$poolname"/swap
# /dev/zvol/"$poolname"/swap none swap discard 0 0
#
# echo "ZFS tmp partition"
# zfs create -o setuid=off -o devices=off -o sync=disabled -o mountpoint=/tmp -o atime=off "$poolname"/tmp
## note: if you want /tmp on ZFS, mask (disable) systemd's automatic tmpfs-backed /tmp
# systemctl mask tmp.mount
#
# echo "RDBMS partition (MySQL/PostgreSQL/Oracle)"
# zfs create -o recordsize=8K -o primarycache=metadata -o mountpoint=/rdbms -o logbias=throughput "$poolname"/rdbms

#script Finish
echo -e '\033[1;33m Finished....please restart the server \033[0m'
