#!/bin/bash
date
# 设置环境变量
vm_num="102"
nas_ip="198.19.1.99"

# 获取UPS状态
ups_status=$(/usr/bin/upsc ups@${nas_ip} | grep 'ups.status' | grep -o 'OL') || ups_status2=$(/usr/bin/upsc ups@${nas_ip} | grep 'ups.status' | grep -o 'OB')
if [[ "${ups_status}" == "OL" ]];then
    upsstatus="OL"
elif [[ "${ups_status}" == "OB" ]];then
    upsstatus="OB"
fi

# 开始运行
if [[ "${upsstatus}" == "OL" ]]
then
	echo "本次脚本第${num_list}个循环"
    # 检测nas是否运行
    if !  ping -c 1 ${nas_ip} &> /dev/null;then
        # nas关机了
        nas_status=0
    else
        # nas运行中
        nas_status=1
    fi

    # 检测虚拟机状态
    if [[ $(/usr/sbin/qm status ${vm_num} | egrep -o "stopped") ]];then
        # 虚拟机已经关机
        vm_status=0
    elif [[ $(/usr/sbin/qm status ${vm_num} | egrep -o "running") ]];then
            vm_status=1
    fi

    # 判断并进行操作
    if [[ ${vm_status} -eq 1 && ${nas_status} -eq 0 ]];then
        /usr/sbin/qm stop ${vm_num} --skiplock true
        echo "NAS已经关机，关闭虚拟机"
    elif [[ ${vm_status} -eq 0 && ${nas_status} -eq 1 ]];then
        /usr/sbin/qm start ${vm_num}
        echo "NAS运行中，开启虚拟机"
    elif [[ ${vm_status} -eq 1 && ${nas_status} -eq 1 ]];then
        echo "一切正常"
    elif [[ ${vm_status} -eq 0 && ${nas_status} -eq 0 ]];then
        echo "全部关闭"
    fi
fi
echo -e '\n\n'