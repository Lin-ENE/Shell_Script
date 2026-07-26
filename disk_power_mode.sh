#!/bin/bash
disk_name=`lsblk | grep 'sd. ' | sed 's/\(sd[a-z]\) .*/\1/g' | sed  ':a;N;$!ba;s/\n/ /g'`
for i in ${disk_name}
    do
    echo "当前显示硬盘${i}"
    smartctl -i -n standby /dev/${i} | grep "mode"                    | sed 's/Power mode is/电源模式是(Power mode is)/g'
done