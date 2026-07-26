#!/bin/bash
disk_name=(`lsblk | grep 'sd. ' | sed 's/\(sd[a-z]\) .*/\1/g' | sed  ':a;N;$!ba;s/\n/ /g'`)
echo ${disk_name}
for ((i=0;$i<${#disk_name[@]};i++))
    do
        echo 'ID#          ATTRIBUTE_NAME                      FLAG    VALUE WORST THRESH  TYPE     UPDATED WHEN_FAILED RAW_VALUE'
        echo "当前显示硬盘${disk_name[$i]}"
        smartctl -A /dev/${disk_name[$i]}            | grep 'Power_On_Hours'          | sed 's/Power_On_Hours/硬盘加电时间(Power_On_Hours)       /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'UDMA_CRC_Error_Count'    | sed 's/UDMA_CRC_Error_Count/UltraDMA通讯CRC错误(UDMA_CRC_Error_Count)/g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'Raw_Read_Error_Rate'     | sed 's/Raw_Read_Error_Rate/底层数据读取错误率(Raw_Read_Error_Rate) /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'Reallocated_Sector_Ct'   | sed 's/Reallocated_Sector_Ct/重定位磁区计数(Reallocated_Sector_Ct)     /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'End-to-End_Error'        | sed 's/End-to-End_Error/终端校验出错(End-to-End_Error)       /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'Spin_Retry_Count'        | sed 's/Spin_Retry_Count/电机起转重试(Spin_Retry_Count)       /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'Reallocated_Event_Count' | sed 's/Reallocated_Event_Count/重定位事件计数(Reallocated_Event_Count)     /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'Current_Pending_Sector'  | sed 's/Current_Pending_Sector/等候重定的扇区计数(Current_Pending_Sector) /g'
        smartctl -A /dev/${disk_name[$i]}            | grep 'Offline_Uncorrectable'   | sed 's/Offline_Uncorrectable/无法校正的扇区计数(Offline_Uncorrectable) /g'
        smartctl -i -n standby /dev/${disk_name[$i]} | grep "mode"                    | sed 's/Power mode is/电源模式是(Power mode is)/g'
        smartctl -l error   /dev/${disk_name[$i]}    | sed -n 4,6p
	echo -e '\n\n\n'
    done
