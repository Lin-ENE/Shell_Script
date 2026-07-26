#!/usr/bin/env bash
# NUT upssched command handler for a Proxmox VE host (QEMU VMs only).
#
# Install as /etc/nut/upssched.sh, owned by root and not writable by nut:
#   chown root:root /etc/nut/upssched.sh
#   chmod 0755 /etc/nut/upssched.sh
#
# Run privileged actions through this script instead of adding nut to the sudo
# group. Example /etc/sudoers.d/nut-upssched (keep the script path identical):
#
#   Cmnd_Alias NUT_UPSSCHED = /etc/nut/upssched.sh NOTIFY-ONBATT, \
#       /etc/nut/upssched.sh NOTIFY-ONLINE, \
#       /etc/nut/upssched.sh FORCE-FSD, \
#       /etc/nut/upssched.sh NOTIFY-LOWBATT, \
#       /etc/nut/upssched.sh CHECK
#   nut ALL=(root) NOPASSWD: NUT_UPSSCHED
#
# Validate the deployment with:
#   sudo -u nut /etc/nut/upssched.sh CHECK

set -uo pipefail

# ========================
# Configuration
# ========================
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

LOG_TAG='upssched-cmd'
UPS_TARGET='ups@127.0.0.1'
VM_SHUTDOWN_TIMEOUT=50
UPS_STATUS_RETRIES=2
UPS_STATUS_RETRY_DELAY=2
LOCK_WAIT=5

# VM IDs that must not be started automatically when mains power returns.
# They are still shut down on battery and force-stopped before FSD.
SPEC_LIST=(102)

STATE_FILE='/run/nut/upssched-vms.state'
SHUTDOWN_DEADLINE_FILE='/run/nut/upssched-shutdown.deadline'
ACTION_LOCK_FILE='/run/nut/upssched-action.lock'

LOGGER_BIN='/usr/bin/logger'
SUDO_BIN='/usr/bin/sudo'
UPSC_BIN='/usr/bin/upsc'
QM_BIN='/usr/sbin/qm'
UPSMON_BIN='/usr/sbin/upsmon'
FLOCK_BIN='/usr/bin/flock'

LOCK_HELD=0
UPS_STATUS='UNKNOWN'
QM_STOP_OVERRULE_SUPPORTED='UNKNOWN'

# ========================
# Logging and command wrappers
# ========================
log() {
    local message="$*"

    if [[ -x $LOGGER_BIN ]]; then
        "$LOGGER_BIN" -t "$LOG_TAG" -- "$message" 2>/dev/null || true
    fi
    printf '%(%Y-%m-%d %H:%M:%S)T [%s] %s\n' -1 "$LOG_TAG" "$message" >&2
}

run_qm() {
    "$QM_BIN" "$@"
}

run_upsc() {
    "$UPSC_BIN" "$@"
}

run_upsmon() {
    "$UPSMON_BIN" "$@"
}

# ========================
# Action and privilege handling
# ========================
valid_action() {
    case "$1" in
        NOTIFY-ONBATT|NOTIFY-ONLINE|FORCE-FSD|NOTIFY-LOWBATT|CHECK|\
        NOTIFY-FSD|NOTIFY-SHUTDOWN|NOTIFY-REPLBATT|NOTIFY-NOCOMM|\
        NOTIFY-COMMBAD|COMMOK)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

privileged_action() {
    case "$1" in
        NOTIFY-ONBATT|NOTIFY-ONLINE|FORCE-FSD|NOTIFY-LOWBATT|CHECK)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_root() {
    local action=$1
    local script_path

    (( EUID == 0 )) && return 0

    if [[ ! -x $SUDO_BIN ]]; then
        log "需要 root 权限，但未找到 sudo: $SUDO_BIN"
        return 77
    fi

    script_path=$(readlink -f -- "${BASH_SOURCE[0]}") || {
        log '无法确定脚本的绝对路径，不能通过 sudo 重新执行'
        return 77
    }

    exec "$SUDO_BIN" -n -- "$script_path" "$action"
}

# ========================
# Locking
# ========================
acquire_lock() {
    local lock_dir
    lock_dir=$(dirname -- "$ACTION_LOCK_FILE")

    if ! mkdir -p -- "$lock_dir"; then
        log "无法创建锁目录: $lock_dir"
        return 1
    fi

    if ! exec 200>"$ACTION_LOCK_FILE"; then
        log "无法打开动作锁: $ACTION_LOCK_FILE"
        return 1
    fi

    if ! "$FLOCK_BIN" -w "$LOCK_WAIT" 200; then
        exec 200>&-
        log "已有 UPS 动作正在执行，等待 ${LOCK_WAIT}s 后仍未取得锁"
        return 1
    fi

    LOCK_HELD=1
}

release_lock() {
    if (( LOCK_HELD )); then
        "$FLOCK_BIN" -u 200 2>/dev/null || true
        exec 200>&-
        LOCK_HELD=0
    fi
}

cleanup() {
    release_lock
}

# ========================
# UPS status
# ========================
read_ups_status() {
    local attempt raw

    UPS_STATUS='UNKNOWN'
    for ((attempt = 1; attempt <= UPS_STATUS_RETRIES; attempt++)); do
        if raw=$(run_upsc "$UPS_TARGET" ups.status 2>/dev/null); then
            raw=${raw//$'\n'/ }
            raw=${raw//$'\r'/ }
            if [[ -n ${raw//[[:space:]]/} ]]; then
                UPS_STATUS=$raw
                return 0
            fi
        fi

        if (( attempt < UPS_STATUS_RETRIES )); then
            sleep "$UPS_STATUS_RETRY_DELAY"
        fi
    done

    return 1
}

ups_has_status() {
    local wanted=$1 token
    for token in $UPS_STATUS; do
        [[ $token == "$wanted" ]] && return 0
    done
    return 1
}

refresh_and_log_ups_status() {
    if read_ups_status; then
        log "UPS 状态: $UPS_STATUS"
        return 0
    fi

    log "无法读取 UPS 状态，按 UNKNOWN 处理"
    return 1
}

# ========================
# VM discovery and state
# ========================
is_recovery_excluded_vm() {
    local vm=$1 excluded
    for excluded in "${SPEC_LIST[@]}"; do
        [[ $vm == "$excluded" ]] && return 0
    done
    return 1
}

list_running_vms() {
    local output

    if ! output=$(run_qm list 2>&1); then
        log "读取 VM 列表失败: $output"
        return 1
    fi

    awk 'NR > 1 && $1 ~ /^[0-9]+$/ && $3 == "running" { print $1 }' <<<"$output"
}

vm_status() {
    local vm=$1 output status

    if ! output=$(run_qm status "$vm" 2>&1); then
        return 1
    fi

    status=$(awk '$1 == "status:" { print $2; exit }' <<<"$output")
    [[ -n $status ]] || return 1
    printf '%s\n' "$status"
}

vm_onboot_enabled() {
    local vm=$1 output onboot

    if ! output=$(run_qm config "$vm" 2>&1); then
        log "读取 VM $vm 的 onboot 配置失败: $output"
        return 2
    fi

    onboot=$(awk -F':[[:space:]]*' '$1 == "onboot" { print $2; exit }' <<<"$output")
    [[ $onboot == 1 ]]
}

load_state() {
    [[ -f $STATE_FILE ]] || return 0
    awk '/^[0-9]+$/ && !seen[$0]++ { print $0 }' "$STATE_FILE"
}

write_state() {
    local state_dir tmp
    local -a vms=("$@")

    state_dir=$(dirname -- "$STATE_FILE")
    if ! mkdir -p -- "$state_dir"; then
        log "无法创建状态目录: $state_dir"
        return 1
    fi

    if ((${#vms[@]} == 0)); then
        rm -f -- "$STATE_FILE"
        return 0
    fi

    if ! tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX"); then
        log "无法为状态文件创建临时文件: $STATE_FILE"
        return 1
    fi

    chmod 0600 "$tmp" || true
    if ! printf '%s\n' "${vms[@]}" >"$tmp"; then
        rm -f -- "$tmp"
        log "无法写入 VM 状态文件: $STATE_FILE"
        return 1
    fi

    if ! mv -f -- "$tmp" "$STATE_FILE"; then
        rm -f -- "$tmp"
        log "无法原子更新 VM 状态文件: $STATE_FILE"
        return 1
    fi
}


set_shutdown_deadline() {
    local state_dir tmp now deadline

    state_dir=$(dirname -- "$SHUTDOWN_DEADLINE_FILE")
    mkdir -p -- "$state_dir" || return 1
    now=$(date +%s) || return 1
    deadline=$((now + VM_SHUTDOWN_TIMEOUT + 2))

    tmp=$(mktemp "${SHUTDOWN_DEADLINE_FILE}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$deadline" >"$tmp" || ! mv -f -- "$tmp" "$SHUTDOWN_DEADLINE_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

wait_for_graceful_shutdown() {
    local deadline now remaining sleep_for vm status
    local any_running
    local -a tracked=()

    [[ -f $SHUTDOWN_DEADLINE_FILE ]] || return 0
    read -r deadline <"$SHUTDOWN_DEADLINE_FILE" || deadline=0
    if [[ ! $deadline =~ ^[0-9]+$ ]]; then
        rm -f -- "$SHUTDOWN_DEADLINE_FILE"
        return 0
    fi

    mapfile -t tracked < <(load_state)
    if ((${#tracked[@]} == 0)); then
        rm -f -- "$SHUTDOWN_DEADLINE_FILE"
        return 0
    fi

    while :; do
        now=$(date +%s) || break
        (( now < deadline )) || break

        any_running=0
        for vm in "${tracked[@]}"; do
            if status=$(vm_status "$vm" 2>/dev/null) && [[ $status == running ]]; then
                any_running=1
                break
            fi
        done
        (( any_running )) || break

        remaining=$((deadline - now))
        sleep_for=2
        (( remaining < sleep_for )) && sleep_for=$remaining
        (( sleep_for > 0 )) && sleep "$sleep_for"
    done

    rm -f -- "$SHUTDOWN_DEADLINE_FILE"
}

collect_tracked_vms() {
    local vm running_output
    local -A seen=()
    local -a existing=() running=()

    mapfile -t existing < <(load_state)
    if ! running_output=$(list_running_vms); then
        return 1
    fi
    if [[ -n $running_output ]]; then
        mapfile -t running <<<"$running_output"
    fi

    for vm in "${existing[@]}" "${running[@]}"; do
        [[ $vm =~ ^[0-9]+$ ]] || continue
        seen["$vm"]=1
    done

    if ((${#seen[@]})); then
        printf '%s\n' "${!seen[@]}" | sort -n
    fi
}

# ========================
# VM operations
# ========================
launch_graceful_shutdown() {
    local vm=$1

    log "请求 VM $vm 优雅关机（最长等待 ${VM_SHUTDOWN_TIMEOUT}s）"

    # Do not let the detached worker keep the action lock or command pipe open.
    (
        trap - EXIT INT TERM
        exec 200>&-
        if output=$(run_qm shutdown "$vm" --timeout "$VM_SHUTDOWN_TIMEOUT" --forceStop 0 2>&1); then
            "$LOGGER_BIN" -t "$LOG_TAG" -- "VM $vm 已完成优雅关机" 2>/dev/null || true
        else
            "$LOGGER_BIN" -t "$LOG_TAG" -- "VM $vm 优雅关机未完成: $output" 2>/dev/null || true
        fi
    ) </dev/null >/dev/null 2>&1 &
}

qm_stop_supports_overrule_shutdown() {
    local output

    case "$QM_STOP_OVERRULE_SUPPORTED" in
        YES) return 0 ;;
        NO)  return 1 ;;
    esac

    output=$(run_qm help stop 2>&1 || true)
    if grep -q -- '--overrule-shutdown' <<<"$output"; then
        QM_STOP_OVERRULE_SUPPORTED='YES'
        log 'qm stop 支持 --overrule-shutdown，将终止仍在执行的关机任务后强停 VM'
        return 0
    fi

    QM_STOP_OVERRULE_SUPPORTED='NO'
    log '当前 qm stop 不支持 --overrule-shutdown，使用 --skiplock 强制停止'
    return 1
}

force_stop_vms() {
    local vm status output
    local -a vms=("$@") stop_args=()

    for vm in "${vms[@]}"; do
        if ! status=$(vm_status "$vm"); then
            log "无法读取 VM $vm 状态，跳过强制停止"
            continue
        fi
        [[ $status == running ]] || continue

        stop_args=("$vm" --skiplock true)
        if qm_stop_supports_overrule_shutdown; then
            stop_args+=(--overrule-shutdown true)
        fi

        log "强制停止仍在运行的 VM $vm"
        if ! output=$(run_qm stop "${stop_args[@]}" 2>&1); then
            log "强制停止 VM $vm 失败，继续执行 FSD: $output"
        fi
    done
}

recover_tracked_vms() {
    local vm status output
    local -a tracked=() pending=()

    mapfile -t tracked < <(load_state)
    if ((${#tracked[@]} == 0)); then
        log '没有需要恢复的 VM'
        return 0
    fi

    for vm in "${tracked[@]}"; do
        if ! status=$(vm_status "$vm"); then
            log "VM $vm 不存在或无法读取状态，从恢复列表移除"
            continue
        fi

        case "$status" in
            running)
                log "VM $vm 已在运行"
                ;;
            stopped)
                if is_recovery_excluded_vm "$vm"; then
                    log "VM $vm 位于 SPEC_LIST，等待外部服务准备完成后启动"
                    continue
                fi

                if vm_onboot_enabled "$vm"; then
                    log "VM $vm 已设置 onboot=1，恢复启动"
                    if ! output=$(run_qm start "$vm" 2>&1); then
                        log "启动 VM $vm 失败，保留待恢复记录: $output"
                        pending+=("$vm")
                    fi
                else
                    case $? in
                        1)
                            log "VM $vm 未设置 onboot=1，不自动恢复"
                            ;;
                        *)
                            log "无法确认 VM $vm 的 onboot 配置，保留待恢复记录"
                            pending+=("$vm")
                            ;;
                    esac
                fi
                ;;
            *)
                log "VM $vm 当前状态为 $status，保留待恢复记录"
                pending+=("$vm")
                ;;
        esac
    done

    if ((${#pending[@]})); then
        write_state "${pending[@]}"
        return 1
    fi

    rm -f -- "$STATE_FILE"
    log '本次断电关闭的 VM 已全部恢复'
}

# ========================
# Event handlers
# ========================
handle_on_battery() {
    local vm tracked_output
    local -a tracked=()

    acquire_lock || return 75
    refresh_and_log_ups_status || true

    if ups_has_status OL; then
        log '市电已经恢复，忽略迟到的 ONBATT 通知'
        return 0
    fi

    if ! tracked_output=$(collect_tracked_vms); then
        log '无法取得 VM 列表；保留 NUT 最终 FSD 定时器，但不执行 VM 操作'
        return 1
    fi
    if [[ -n $tracked_output ]]; then
        mapfile -t tracked <<<"$tracked_output"
    fi

    if ! write_state "${tracked[@]}"; then
        log '无法保存完整的 VM 恢复列表；继续请求关机'
    fi

    if ((${#tracked[@]} == 0)); then
        rm -f -- "$SHUTDOWN_DEADLINE_FILE"
        log '当前没有需要关闭的运行中 VM'
        return 0
    fi

    if ! set_shutdown_deadline; then
        log '无法记录优雅关机截止时间；市电恢复时将直接按当前状态恢复'
    fi

    log "断电处理开始，共 ${#tracked[@]} 个 VM；NUT 将在 60 秒计时结束后执行 FSD"
    for vm in "${tracked[@]}"; do
        if [[ $(vm_status "$vm" 2>/dev/null || true) == running ]]; then
            launch_graceful_shutdown "$vm"
        fi
    done
}

handle_online() {
    acquire_lock || return 75
    refresh_and_log_ups_status || true

    if ! ups_has_status OL; then
        log '尚未确认市电为 OL，暂不恢复 VM'
        return 1
    fi

    log '市电恢复，等待已发出的 VM 关机请求结束'
    wait_for_graceful_shutdown
    refresh_and_log_ups_status || true
    if ! ups_has_status OL; then
        log '等待期间再次断电，不启动 VM；保留恢复列表供后续处理'
        return 1
    fi

    log '开始恢复本次断电关闭的 VM'
    recover_tracked_vms
}

handle_force_fsd() {
    local reason=${1:-定时器到期}
    local running_output
    local -a tracked=()

    acquire_lock || return 75
    refresh_and_log_ups_status || true

    if ups_has_status OL; then
        log "$reason，但市电已经恢复；等待已发出的 VM 关机请求结束"
        wait_for_graceful_shutdown
        refresh_and_log_ups_status || true
        if ups_has_status OL; then
            log '市电保持在线，取消 FSD 并恢复 VM'
            recover_tracked_vms
            return $?
        fi
        log '等待期间再次断电，继续执行强制停止和 FSD'
    fi

    mapfile -t tracked < <(load_state)
    if ((${#tracked[@]} == 0)); then
        log '没有找到状态文件，改为检查当前所有运行中的 VM'
        if running_output=$(list_running_vms); then
            if [[ -n $running_output ]]; then
                mapfile -t tracked <<<"$running_output"
            fi
        else
            tracked=()
        fi
    fi

    if ((${#tracked[@]})); then
        force_stop_vms "${tracked[@]}"
    else
        log '没有仍需处理的 VM'
    fi

    log "$reason，触发 NUT FSD"
    if ! run_upsmon -c fsd; then
        log '执行 upsmon -c fsd 失败'
        return 1
    fi
}

handle_check() {
    local failed=0 command_path state_dir output

    for command_path in "$LOGGER_BIN" "$SUDO_BIN" "$UPSC_BIN" "$QM_BIN" "$UPSMON_BIN" "$FLOCK_BIN"; do
        if [[ -x $command_path ]]; then
            log "CHECK OK: $command_path"
        else
            log "CHECK FAIL: 命令不存在或不可执行: $command_path"
            failed=1
        fi
    done

    state_dir=$(dirname -- "$STATE_FILE")
    if mkdir -p -- "$state_dir" && [[ -w $state_dir ]]; then
        log "CHECK OK: 状态目录可写: $state_dir"
    else
        log "CHECK FAIL: 状态目录不可写: $state_dir"
        failed=1
    fi

    if output=$(run_qm list 2>&1); then
        log 'CHECK OK: qm list 可执行'
    else
        log "CHECK FAIL: qm list 失败: $output"
        failed=1
    fi

    if read_ups_status; then
        log "CHECK OK: $UPS_TARGET ups.status=$UPS_STATUS"
    else
        log "CHECK FAIL: 无法读取 $UPS_TARGET 的 ups.status"
        failed=1
    fi

    return "$failed"
}

main() {
    local action=${1:-}
    local rc=0

    if [[ -z $action ]]; then
        log '缺少事件参数'
        return 64
    fi
    if ! valid_action "$action"; then
        log "未知命令: $action"
        return 64
    fi

    if privileged_action "$action"; then
        ensure_root "$action" || return $?
    fi

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    log "处理事件: $action (uid=$(id -u), pid=$$)"

    case "$action" in
        NOTIFY-ONBATT)
            handle_on_battery || rc=$?
            ;;
        NOTIFY-ONLINE)
            handle_online || rc=$?
            ;;
        FORCE-FSD)
            handle_force_fsd '断电持续 60 秒' || rc=$?
            ;;
        NOTIFY-LOWBATT)
            handle_force_fsd 'UPS 电量不足' || rc=$?
            ;;
        CHECK)
            handle_check || rc=$?
            ;;
        NOTIFY-FSD)
            log 'NUT 已进入 FSD 状态，等待 upsmon 执行系统关机流程'
            ;;
        NOTIFY-SHUTDOWN)
            log 'upsmon 即将执行系统关机'
            ;;
        NOTIFY-REPLBATT)
            log 'UPS 需要更换电池'
            ;;
        NOTIFY-NOCOMM)
            log 'UPS 无法连接'
            ;;
        NOTIFY-COMMBAD)
            log 'UPS 通信异常持续超过 30 秒'
            ;;
        COMMOK)
            log 'UPS 通信已经恢复'
            ;;
    esac

    return "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi