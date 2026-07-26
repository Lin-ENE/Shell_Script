#!/bin/bash
# 打印时间
date +"%Y-%m-%d %H:%M:%S"

# ==================== 参数解析开始 ====================
info_only_mode=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--info|--info-only)
            info_only_mode=true
            shift
            ;;
        *)
            # 忽略其他未知参数
            shift
            ;;
    esac
done
# ==================== 参数解析结束 ====================

# 环境变量
# 设置可调参数
# 强制安静（最低频率运行）
force_quiet=enable
# 是否启用IPMI
ipmi_enable=enable

# 夜晚模式开启以及关闭时间
night_quiet=false
night_start_time="23:00"
night_stop_time="06:00"

# 频率调节策略
cpu_power_mode="schedutil"
cpu_high_freq_power_mode="performance"

# 温度设置
cpu_normal_temp_limit=80
cpu_super_temp_limit=90
cpu_super_temp_plus_limit=95

# 频率设置 (KHz)
cpu_normal_temp_limit_max_freq=$((2800 * 1000))
cpu_super_temp_limit_max_freq=$((2600 * 1000)) 
cpu_super_plus_temp_limit_max_freq=$((2000 * 1000))
cpu_temp_limit_min_freq=$((1200 * 1000))

# CPU占用设置
cpu_min_idle=40
app_use_max_cpu_limit=150

# 日志级别 debug-1, info-2, warn-3, error-4, always-5 
LOG_LEVEL=1
LOG_FILE="/mnt/volume-pool-logs/volume-logs/logs/thermalGovernor.log"

# 特殊模式
only_cpufreq_mode=false

# 脚本自身名称（用于在ps中排除）
SCRIPT_NAME=$(basename "$0")

# ——————————————————————————————日志输出等级函数——————————————————————————————
function log_debug() { 
    local content="$(date '+%Y-%m-%d %H:%M:%S') $*" 
    [ "${LOG_LEVEL}" -le 1 ] && echo -e "[ DEBUG ] ${content}" >> "${LOG_FILE}" && echo -e "\033[46;37m[DEBUG]\033[0m \033[36m${content}\033[0m" 
} 
function log_info() { 
    local content="$(date '+%Y-%m-%d %H:%M:%S') $*" 
    [ "${LOG_LEVEL}" -le 2 ] && echo -e "[ INFO ] ${content}" >> "${LOG_FILE}" && echo -e "\033[42;37m[INFO]\033[0m \033[32m${content}\033[0m" 
} 
function log_warn() { 
    local content="$(date '+%Y-%m-%d %H:%M:%S') $*" 
    [ "${LOG_LEVEL}" -le 3 ] && echo -e "[ WARN ] ${content}" >> "${LOG_FILE}" && echo -e "\033[43;37m[WARN]\033[0m \033[33m${content}\033[0m" 
} 
function log_err() { 
    local content="$(date '+%Y-%m-%d %H:%M:%S') $*" 
    [ "${LOG_LEVEL}" -le 4 ] && echo -e "[ ERROR ] ${content}" >> "${LOG_FILE}" && echo -e "\033[41;37m[ERROR]\033[0m \033[31m${content}\033[0m" 
} 
function log_always() { 
    local content="$(date '+%Y-%m-%d %H:%M:%S') $*" 
    [ "${LOG_LEVEL}" -le 5 ] && echo -e "[ ALWAYS ] ${content}" >> "${LOG_FILE}" && echo -e "\033[45;37m[ALWAYS]\033[0m \033[35m${content}\033[0m" 
} 
function log_ok() { 
    local content="$(date '+%Y-%m-%d %H:%M:%S') $*" 
    [ "${LOG_LEVEL}" -le 5 ] && echo -e "[ OK ] ${content}" >> "${LOG_FILE}" && echo -e "\033[32m[ OK ] \033[0m${content}"
} 

# ——————————————————————————————检测运行条件——————————————————————————————
function check_run_shell_condition() {
    log_debug "检测是否安装IPMItool"
    if ! type "ipmitool" > /dev/null 2>&1; then
        log_warn "未检测到ipmitool，关闭IPMI功能"
        ipmi_enable=false
    fi
    log_ok "IPMITOOL检测完成"

    log_debug "正在检查依赖的命令..."
    local check_cmd_list=(top cpupower sed grep cat sort date uniq head awk sensors)
    local check_cmd_status="success"

    for cmd_name in "${check_cmd_list[@]}"; do
        if ! type "${cmd_name}" > /dev/null 2>&1; then
            log_err "请先安装: ${cmd_name}"
            check_cmd_status="fail"
        fi
    done

    log_debug "正在检查所需文件..."
    local check_file_list=("/proc/cpuinfo" "/sys/devices/system/cpu/cpu0/cpufreq/")
    local check_file_status="success"

    for file_name in "${check_file_list[@]}"; do
        if [ ! -e "${file_name}" ]; then
            log_err "缺少关键路径: ${file_name}"
            check_file_status="fail"
        fi
    done

    if [[ "${check_file_status}" == "fail" || "${check_cmd_status}" == "fail" ]]; then
        log_err "环境检测失败，程序退出"
        exit 1
    fi
    log_ok "依赖环境检测通过"
}

# ——————————————————————————————变量合法性检测与初始化——————————————————————————————
function check_var_whether_null() {
    # 默认值处理
    : "${LOG_LEVEL:=2}"
    : "${LOG_FILE:=/dev/null}"

    # 获取CPU物理插槽数和核心数
    cpu_count_list=($(cat /proc/cpuinfo | grep "physical id" | sort | uniq | awk '{print $NF}'))
    if [ ${#cpu_count_list[@]} -eq 0 ]; then
        log_warn "无法检测CPU物理插槽数量，默认设置为 0"
        cpu_count_list=(0)
    fi

    # 获取所有逻辑CPU核心编号列表
    cpu_core_count_list=($(seq 0 $(( $(nproc) - 1 ))))
    log_info "检测到逻辑CPU核心总数: ${#cpu_core_count_list[@]} 个"

    : "${ipmi_enable:=false}"
    : "${night_quiet:=false}"

    # 检查调频驱动支持的Governors
    local cpu_power_mode_list=($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors))
    log_debug "支持的调频模式: ${cpu_power_mode_list[*]}"

    local valid_governor=0
    local valid_high_governor=0
    for mode in "${cpu_power_mode_list[@]}"; do
        [[ "${cpu_power_mode}" == "${mode}" ]] && valid_governor=1
        [[ "${cpu_high_freq_power_mode}" == "${mode}" ]] && valid_high_governor=1
    done

    if [ ${valid_governor} -eq 0 ]; then
        log_warn "原设置 cpu_power_mode 无效，默认使用 powersave"
        cpu_power_mode="powersave"
    fi
    if [ ${valid_high_governor} -eq 0 ]; then
        log_warn "原设置 cpu_high_freq_power_mode 无效，默认使用 performance"
        cpu_high_freq_power_mode="performance"
    fi

    : "${cpu_min_idle:=40}"
    : "${app_use_max_cpu_limit:=150}"
    : "${only_cpufreq_mode:=false}"
    log_ok "核心变量初始化成功"
}

# ——————————————————————————————IPMI风扇与温度控制——————————————————————————————
function cpu_info_get_from_ipmi() {
    if [[ "${ipmi_enable}" == "enable" ]]; then
        log_debug "正在通过IPMI获取CPU温度与风扇模式"
        cpu_temp_ipmi_get=0

        for cpu_id in "${cpu_count_list[@]}"; do
            local cpu_idx=$((cpu_id + 1))
            local temp_reading
            temp_reading=$(ipmitool sdr | grep -i "CPU${cpu_idx} Temp" | awk -F'|' '{print $2}' | grep -o '[0-9]\+' | head -n 1)
            
            if [ -n "${temp_reading}" ]; then
                cpu_info_ipmi_get_temp[${cpu_id}]=${temp_reading}
                if [[ "${cpu_temp_ipmi_get}" -lt "${cpu_info_ipmi_get_temp[${cpu_id}]}" ]]; then
                    cpu_temp_ipmi_get=${cpu_info_ipmi_get_temp[${cpu_id}]}
                fi
                log_debug "CPU${cpu_idx} IPMI温度为: ${cpu_info_ipmi_get_temp[${cpu_id}]}°C"
            fi
        done

        fan_mode_get=$(ipmitool raw 0x30 0x45 0x00 | egrep -o '[0-9]{2}' | head -n 1)
        log_ok "IPMI信息读取完成"
    else
        cpu_temp_ipmi_get=0
        fan_mode_get="00"
    fi
}

function ipmi_fans_mode_set() {
    if [[ "${ipmi_enable}" == "enable" ]]; then
        ipmitool raw 0x30 0x45 0x01 "0x${1}" > /dev/null 2>&1
        case "${1}" in
            "00") log_ok "风扇模式调整为: Standard Speed" ;;
            "01") log_ok "风扇模式调整为: Full Speed"     ;;
            "02") log_ok "风扇模式调整为: Optimal Speed"  ;;
        esac
    fi
}

function ipmi_fans_mode_echo() {
    if [[ "${ipmi_enable}" == "enable" ]]; then
        case "${fan_mode_get}" in
            "00") log_info "当前风扇模式: Standard Speed" ;;
            "01") log_info "当前风扇模式: Full Speed"     ;;
            "02") log_info "当前风扇模式: Optimal Speed"  ;;
        esac
    fi
}

function ipmi_sensor_cpu_upper() {
    if [[ "${ipmi_enable}" == "enable" ]]; then
        log_debug "IPMI正在设置温度墙..."
        for cpu_id in "${cpu_count_list[@]}"; do
            local cpu_idx=$((cpu_id + 1))
            ipmitool sensor thresh "CPU${cpu_idx} Temp" upper "${1}" "${2}" "${3}" > /dev/null 2>&1
        done
        log_ok "IPMI温度阈值设置完毕: 警告=${1}°, 关键=${2}°, 致命=${3}°"
    fi
}

# ——————————————————————————————系统信息采集——————————————————————————————
function cpu_info_get_from_sys() {
    log_debug "正在采集CPU频率信息"
    cpu_max_freq_get=0
    cpu_min_freq_get=0
    cpu_now_freq_get=0

    for core_id in "${cpu_core_count_list[@]}"; do
        local max_f=$(cat "/sys/devices/system/cpu/cpu${core_id}/cpufreq/scaling_max_freq" 2>/dev/null)
        local min_f=$(cat "/sys/devices/system/cpu/cpu${core_id}/cpufreq/scaling_min_freq" 2>/dev/null)
        local cur_f=$(cat "/sys/devices/system/cpu/cpu${core_id}/cpufreq/scaling_cur_freq" 2>/dev/null)

        [[ -n "${max_f}" && "${cpu_max_freq_get}" -lt "${max_f}" ]] && cpu_max_freq_get=${max_f}
        [[ -n "${min_f}" && "${cpu_min_freq_get}" -lt "${min_f}" ]] && cpu_min_freq_get=${min_f}
        [[ -n "${cur_f}" && "${cpu_now_freq_get}" -lt "${cur_f}" ]] && cpu_now_freq_get=${cur_f}
    done
    log_ok "CPU频率获取完毕。系统最高限制: ${cpu_max_freq_get} KHz"

    log_debug "正在采集系统温度..."
    cpu_temp_sys_get=0
    cpu_temp_sensors_get=0

    for cpu_id in "${cpu_count_list[@]}"; do
        local sys_temp=0
        if [ -f "/sys/class/thermal/thermal_zone${cpu_id}/temp" ]; then
            sys_temp=$(( $(cat "/sys/class/thermal/thermal_zone${cpu_id}/temp") / 1000 ))
        fi
        [[ "${cpu_temp_sys_get}" -lt "${sys_temp}" ]] && cpu_temp_sys_get=${sys_temp}

        # 通过 sensors 匹配该路 CPU 的温度
        local sense_temp
        sense_temp=$(sensors 2>/dev/null | grep -i "Package id ${cpu_id}" | grep -oE '\+[0-9]{2}' | head -n 1 | tr -d '+')
        if [ -n "${sense_temp}" ]; then
            cpu_info_temp_sensors[${cpu_id}]=${sense_temp}
            if [[ "${cpu_temp_sensors_get}" -lt "${cpu_info_temp_sensors[${cpu_id}]}" ]]; then
                cpu_temp_sensors_get=${cpu_info_temp_sensors[${cpu_id}]}
            fi
        fi
    done

    # 取 sensors 与 thermal_zone 的最大值
    [[ "${cpu_temp_sys_get}" -lt "${cpu_temp_sensors_get}" ]] && cpu_temp_sys_get=${cpu_temp_sensors_get}
    log_ok "采集到最高核心温度: ${cpu_temp_sys_get}°C"

    # 获取空闲与软件占用
    log_debug "获取CPU空闲率和进程占用..."
    cpu_idle=$(top -bcn 1 -w 200 | grep '%Cpu(s)' | sed 's/.*ni,//g; s/\..*id,.*//g' | awk '{print $1}' | head -n 1)
    : "${cpu_idle:=100}"

    # 排除脚本自身与 qemu
    app_use_max_cpu=$(ps -eo pcpu,comm --sort=-pcpu | grep -vE "(COMMAND|qemu|${SCRIPT_NAME})" | head -n 1 | awk '{print int($1)}')
    : "${app_use_max_cpu:=0}"

    log_ok "CPU状态: 空闲率=${cpu_idle}%, 单进程最高占用=${app_use_max_cpu}%"
}

function CPU_INFO_COMPARED() {
    if [[ "${cpu_temp_sys_get}" -lt "${cpu_temp_ipmi_get}" ]]; then
        cpu_temp_high_get=${cpu_temp_ipmi_get}
    else
        cpu_temp_high_get=${cpu_temp_sys_get}
    fi
    log_ok "最终判定最高温度为: ${cpu_temp_high_get}°C"
}

# ——————————————————————————————下发调频命令——————————————————————————————
function cpu_freq_set() {
    local target_mode="${1}"
    local target_high="${2}"
    local target_low="${3}"

    log_info "正在下发策略: 模式=[${target_mode}], 范围=[${target_low}KHz - ${target_high}KHz]"
    cpupower -c all frequency-set -g "${target_mode}" -d "${target_low}" -u "${target_high}" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_ok "调频策略下发成功"
    else
        log_err "cpupower 执行失败，请检查运行权限或硬件兼容性"
    fi
}

function Debug_log() {
    log_always "======== 状态汇总 ========"
    log_always "单进程最大占用: ${app_use_max_cpu}%"
    log_always "CPU空闲率: ${cpu_idle}%"
    log_always "CPU最大上限频率: ${cpu_max_freq_get} KHz"
    log_always "CPU最高物理温度: ${cpu_temp_high_get}°C"
    log_always "=========================="
}

# ——————————————————————————————时间校正（夜晚模式）——————————————————————————————
function time_correction() {
    log_debug "正在校准深夜时间段..."
    now_date_time=$(date +%s)
    local s_time="${1}"
    local e_time="${2}"

    local start_sec=$(date -d "${s_time}" +%s)
    local stop_sec=$(date -d "${e_time}" +%s)

    if [ "${stop_sec}" -lt "${start_sec}" ]; then
        if [ "${now_date_time}" -ge "${start_sec}" ]; then
            night_enable_time=${start_sec}
            night_stop_time=$((stop_sec + 86400))
        else
            night_enable_time=$((start_sec - 86400))
            night_stop_time=${stop_sec}
        fi
    else
        night_enable_time=${start_sec}
        night_stop_time=${stop_sec}
    fi
    log_ok "时间校准成功"
}

# ——————————————————————————————主程序流程控制——————————————————————————————
log_always "——————————————— 环境检测中 ———————————————"
check_run_shell_condition
check_var_whether_null
log_always "——————————————— 数据采集开始 ———————————————"
cpu_info_get_from_sys
cpu_info_get_from_ipmi
CPU_INFO_COMPARED
log_always "——————————————— 数据采集完毕 ———————————————"

# 0. 【新功能】只输出系统信息模式
if [[ "${info_only_mode}" == "true" ]]; then
    log_always "================ [ 只读信息模式 ] ================"
    Debug_log
    exit 0
fi

# 1. 仅调频模式
if [[ "${only_cpufreq_mode}" == "true" ]]; then
    log_info "进入[仅调频模式]，重设默认策略后退出"
    cpu_freq_set "${cpu_power_mode}" "${cpu_normal_temp_limit_max_freq}" "${cpu_temp_limit_min_freq}"
    Debug_log
    exit 0
fi

# 2. 强制安静模式
if [[ "${force_quiet}" == "enable" ]]; then
    log_info "触发[强制安静模式]！降低频率与风扇转速"
    cpu_freq_set "${cpu_power_mode}" "${cpu_temp_limit_min_freq}" "${cpu_temp_limit_min_freq}"
    if [[ "${fan_mode_get}" != "02" ]]; then
        ipmi_fans_mode_set "02"
        ipmi_sensor_cpu_upper 105 105 110
    fi
    Debug_log
    exit 0
fi

# 3. 深夜低功耗模式
if [[ "${night_quiet}" == "true" ]]; then
    time_correction "${night_start_time}" "${night_stop_time}"
    if [[ "${now_date_time}" -ge "${night_enable_time}" && "${now_date_time}" -le "${night_stop_time}" ]]; then
        log_info "深夜低功耗时段内..."
        cpu_freq_set "${cpu_power_mode}" "${cpu_temp_limit_min_freq}" "${cpu_temp_limit_min_freq}"
        if [[ "${fan_mode_get}" != "02" ]]; then
            ipmi_fans_mode_set "02"
            ipmi_sensor_cpu_upper 105 105 110
        fi
        Debug_log
        exit 0
    fi
fi

# 4. 正常运行模式调度逻辑
log_always "——————————————— 正在执行正常温控模式 ———————————————"
# 4.1 紧急超高温限制
if [[ "${cpu_temp_high_get}" -ge "${cpu_super_temp_plus_limit}" ]]; then
    log_warn "触发 [紧急温度上限] ! 降频并拉满风扇"
    cpu_freq_set "${cpu_power_mode}" "${cpu_super_plus_temp_limit_max_freq}" "${cpu_temp_limit_min_freq}"
    if [[ "${fan_mode_get}" != "01" ]]; then
        ipmi_fans_mode_set "01"
        ipmi_sensor_cpu_upper 120 120 125
    fi

# 4.2 高温限制
elif [[ "${cpu_temp_high_get}" -ge "${cpu_super_temp_limit}" ]]; then
    log_warn "触发 [高温限额] ! 阶梯式降频"
    cpu_freq_set "${cpu_power_mode}" "${cpu_super_temp_limit_max_freq}" "${cpu_temp_limit_min_freq}"
    if [[ "${fan_mode_get}" != "00" ]]; then
        ipmi_fans_mode_set "00"
        ipmi_sensor_cpu_upper 110 110 115
    fi

# 4.3 正常工作温度
else
    # 动态升频逻辑
    if [[ "${app_use_max_cpu}" -ge "${app_use_max_cpu_limit}" || "${cpu_idle}" -le "${cpu_min_idle}" ]]; then
        log_info "检测到重度负载，提升CPU频率"
        cpu_freq_set "${cpu_high_freq_power_mode}" "${cpu_normal_temp_limit_max_freq}" "${cpu_temp_limit_min_freq}"
        if [[ "${fan_mode_get}" != "00" ]]; then
            ipmi_fans_mode_set "00"
            ipmi_sensor_cpu_upper 110 110 115
        fi
    else
        log_info "负载正常，进入低频节能模式"
        cpu_freq_set "${cpu_power_mode}" "${cpu_temp_limit_min_freq}" "${cpu_temp_limit_min_freq}"
        if [[ "${fan_mode_get}" != "02" ]]; then
            ipmi_fans_mode_set "02"
            ipmi_sensor_cpu_upper 105 105 110
        fi
    fi
fi

log_always "——————————————— 运行结束 ———————————————"
Debug_log