# TrueNas-shell-script
专用于  TrueNAS-SCALE-22.02.4 的定时任务脚本
## cpu-freq-controller.sh
根据cpu温度调节cpu频率，默认采用ipmi和系统来检测温度，没有ipmi或不同请删除ipmi相关命令
## fan-mode-auto.sh
专用超微x9主板风扇策略调节
## auto-start.sh
自动开机，使用时需要设置 expect_date变量，例如：export expect_date=6:30 && /path/auto-start.sh
