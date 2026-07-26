#!/bin/bash
date  +"%Y-%m-%d %H:%M.%S"
if [ ! type rtcwake > /dev/null 2>&1 ] 
then 
    echo "请安装rtcwake" 
    exit
fi
if [ `date +%s` -ge  `date -d "$expect_date" +%s` ];
then
    rtcwake -v -m off -t `date -d "tomorrow $expect_date" +%s`
elif [ `date +%s` -lt  `date -d "$expect_date" +%s` ];
then
    rtcwake -v -m off -t `date -d "$expect_date" +%s`
fi
echo -e "\n"
