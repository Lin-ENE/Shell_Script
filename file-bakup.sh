#!/bin/bash

# Emby主程序相关目录
embyserver_dir=""
# 备份文件存放目录
bak_dir=""
# 时间格式化，如 20220602
DATE=`date +%Y%m%d`
# 备份脚本保存的天数
DEL_DAY=14
targz(){
    if [[ `which pv` == "" ]]; then
        apt install pv -y || yum install pv -y
    elif [[ $1 = '' ]]; then
        exit 1
    fi
    tar -cf - $2 | pv -s $(du -sk $2 | awk '{print $1}') | gzip > $1
}
# 创建日期目录
mkdir -p $bak_dir/$DATE
# 停止Emby Server容器服务

cd $embyserver_dir
#rar a -r -m5 ${bak_dir}/${DATE}/UBS-Docker.rar ./
targz $bak_dir/${DATE}/emby-server.tar.gz ./
echo "UBS-Docker备份完成······"
# 启动Emby Server容器服务

cd ${bak_dir}
# 遍历备份目录下的日期目录
LIST=$(ls $bak_dir)
# 获取7天前的时间，用于作比较，早于该时间的文件将删除
SECONDS=$(date -d  "$(date  +%F) -${DEL_DAY} days" +%s)
for index in ${LIST}
do
    # 对目录名进行格式化，取命名末尾的时间，格式如 20200902
    timeString=$(echo ${index} | egrep -o "?[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]")
    if [ -n "$timeString" ]
    then
        indexDate=${timeString//./-}
        indexSecond=$( date -d ${indexDate} +%s )
        # 与当天的时间做对比，把早于7天的备份文件删除
        if [ $(( $SECONDS- $indexSecond )) -gt 0 ]
        then
            rm -rf `echo $index | sed ':a;N;$!ba;s/\n/ /g'`
        fi
    fi
done
