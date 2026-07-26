#!/bin/bash
arc_size=`expr 80 \* 1024 \* 1024 \* 1024`
if [[ `cat /sys/module/zfs/parameters/zfs_arc_max` -lt ${arc_size} ]]
then
    echo ${arc_size} > /sys/module/zfs/parameters/zfs_arc_max
    cat /sys/module/zfs/parameters/zfs_arc_max
fi
