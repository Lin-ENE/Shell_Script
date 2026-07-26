# NUT + Proxmox VE UPS 自动关机脚本安装说明

本文档说明如何在 Proxmox VE 宿主机上安装 `upssched.sh` 和 `upssched.conf`。

本方案只管理 **QEMU 虚拟机**，不管理 LXC 容器。

## 1. 工作流程

| UPS 事件 | 动作 |
| --- | --- |
| `ONBATT` | 立即记录当前正在运行的 VM，并向这些 VM 发送优雅关机请求 |
| 断电未满 60 秒恢复 | 取消最终关机计时器，只恢复本次关闭且设置了 `onboot=1` 的 VM |
| 持续断电 60 秒 | 强制停止仍未关闭的 VM，然后执行 `upsmon -c fsd` |
| `LOWBATT` | 不再等待 60 秒，立即强停残留 VM，并执行 FSD |
| `FSD` / `SHUTDOWN` | 只记录通知，最终宿主机关机由 `upsmon` 的 `SHUTDOWNCMD` 执行 |

VM 恢复列表保存在：

```text
/run/nut/upssched-vms.state
```

该文件位于 `/run`，宿主机重启后会自动消失。FSD 关机后重新启动宿主机时，VM 启动由 Proxmox VE 的 `onboot/startup` 配置负责。

---

## 2. 前置条件

开始安装前，应确保：

1. Proxmox VE 上已经安装并配置 NUT。
2. `upsd`、UPS 驱动和 `upsmon` 能正常运行。
3. UPS 名称默认为 `ups`，服务地址默认为 `127.0.0.1`。
4. 以下命令存在：

```bash
command -v upsc
command -v upssched
command -v upsmon
command -v qm
command -v flock
command -v sudo
```

检查 UPS 是否可读取：

```bash
upsc ups@127.0.0.1 ups.status
```

正常情况下可能返回：

```text
OL
```

或者：

```text
OL CHRG
```

如果 UPS 名称或地址不同，需要修改 `upssched.sh`：

```bash
UPS_TARGET='ups@127.0.0.1'
```

例如 UPS 名称是 `myups`：

```bash
UPS_TARGET='myups@127.0.0.1'
```

---

## 3. 调整脚本配置

安装前打开 `upssched.sh`，检查配置区。

### 3.1 禁止市电恢复时自动启动指定 VM

所有正在运行的 QEMU VM都会参与断电关机和最终 FSD 前的强制停止。`SPEC_LIST` **只禁止市电恢复时自动启动**，不会跳过断电关机。

默认不额外排除任何 VM：

```bash
SPEC_LIST=()
```

例如 VM `100`、`105` 需要等待 NAS 或其他外部服务准备完成后再启动：

```bash
SPEC_LIST=(100 105)
```

列表中的 VM仍然会：

- 在 `ONBATT` 时收到优雅关机请求；
- 在最终 FSD 前仍未关闭时被强制停止；
- 在 ONLINE 恢复阶段保持 stopped，等待外部脚本启动。

`SPEC_LIST` 的优先级高于 Proxmox 的 `onboot`：即使 VM 设置了 `onboot=1`，位于该列表中时，脚本也不会在市电恢复阶段启动它。

### 3.2 按 Proxmox onboot 配置恢复 VM

市电恢复时，脚本只启动断电前正在运行、当前已经 stopped、设置了 `onboot=1` 且不在 `SPEC_LIST` 中的 VM。

查看 VM 配置：

```bash
qm config VMID | grep '^onboot:'
```

允许脚本在市电恢复后拉起 VM：

```bash
qm set VMID --onboot 1
```

不允许脚本自动拉起，例如依赖 NAS/NFS 的 VM：

```bash
qm set VMID --onboot 0
```

未显示 `onboot` 配置时按 `onboot=0` 处理。依赖 NAS 的 VM可保持 `onboot=0`，待 NAS 准备完成后由外部脚本执行：

```bash
qm start VMID
```

### 3.3 VM 优雅关机时间

默认值：

```bash
VM_SHUTDOWN_TIMEOUT=50
```

NUT 的最终 FSD 计时为 60 秒，因此这里保留约 10 秒用于检查和强制停止仍在运行的 VM。

除非同时调整 `upssched.conf` 中的最终计时，否则不要把该值设置为 60 秒或更大。

### 3.4 最终 FSD 时间

最终关机时间位于 `upssched.conf`：

```text
AT ONBATT * START-TIMER FORCE-FSD 60
```

这表示 UPS 持续使用电池供电 60 秒后，强停残留 VM 并触发 FSD。

如果需要修改该时间，应保证：

```text
VM_SHUTDOWN_TIMEOUT < FORCE-FSD 计时时间
```

---

## 4. 安装脚本和配置

进入保存本项目文件的目录，然后执行：

```bash
sudo install -o root -g root -m 0755 \
    upssched.sh /etc/nut/upssched.sh

sudo install -o root -g root -m 0644 \
    upssched.conf /etc/nut/upssched.conf
```

检查文件权限：

```bash
ls -l /etc/nut/upssched.sh /etc/nut/upssched.conf
```

预期脚本不能由 `nut` 用户修改：

```text
-rwxr-xr-x 1 root root ... /etc/nut/upssched.sh
-rw-r--r-- 1 root root ... /etc/nut/upssched.conf
```

执行静态检查：

```bash
bash -n /etc/nut/upssched.sh
```

如果安装了 ShellCheck，也可以执行：

```bash
shellcheck /etc/nut/upssched.sh
```

---

## 5. 配置 sudo 权限

不要把 `nut` 用户加入完整的 `sudo` 组。应只授权 `nut` 执行本脚本规定的动作。

使用 `visudo` 创建配置：

```bash
sudo visudo -f /etc/sudoers.d/nut-upssched
```

写入以下内容：

```sudoers
Cmnd_Alias NUT_UPSSCHED = /etc/nut/upssched.sh NOTIFY-ONBATT, \
    /etc/nut/upssched.sh NOTIFY-ONLINE, \
    /etc/nut/upssched.sh FORCE-FSD, \
    /etc/nut/upssched.sh NOTIFY-LOWBATT, \
    /etc/nut/upssched.sh CHECK

nut ALL=(root) NOPASSWD: NUT_UPSSCHED
```

设置权限并检查语法：

```bash
sudo chown root:root /etc/sudoers.d/nut-upssched
sudo chmod 0440 /etc/sudoers.d/nut-upssched
sudo visudo -cf /etc/sudoers.d/nut-upssched
```

预期输出类似：

```text
/etc/sudoers.d/nut-upssched: parsed OK
```

验证 `nut` 用户可以执行检查动作：

```bash
sudo -u nut /etc/nut/upssched.sh CHECK
```

`CHECK` 不会关闭 VM，也不会触发 FSD。它会检查：

- `logger`、`sudo`、`upsc`、`qm`、`upsmon` 和 `flock`；
- `/run/nut` 是否可用；
- `qm list` 是否可执行；
- 是否能读取 UPS 状态。

如果最后没有 `CHECK FAIL`，说明脚本运行环境基本正常。

---

## 6. 配置 upsmon 调用 upssched

编辑：

```bash
sudo editor /etc/nut/upsmon.conf
```

确认 `NOTIFYCMD` 指向 `upssched`：

```text
NOTIFYCMD /usr/sbin/upssched
```

使用下面的命令确认实际路径：

```bash
command -v upssched
```

如果输出不是 `/usr/sbin/upssched`，请在 `NOTIFYCMD` 中使用实际路径。

相关事件必须包含 `EXEC`。示例：

```text
NOTIFYFLAG ONLINE   SYSLOG+EXEC
NOTIFYFLAG ONBATT   SYSLOG+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+EXEC
NOTIFYFLAG FSD      SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
NOTIFYFLAG REPLBATT SYSLOG+EXEC
NOTIFYFLAG NOCOMM   SYSLOG+EXEC
NOTIFYFLAG COMMBAD  SYSLOG+EXEC
NOTIFYFLAG COMMOK   SYSLOG+EXEC
```

如果原配置还有 `WALL`，可以继续保留，例如：

```text
NOTIFYFLAG ONBATT SYSLOG+WALL+EXEC
```

不要重复定义同一个 `NOTIFYFLAG`，应修改已有配置。

同时确认 `upsmon.conf` 中已经正确配置宿主机关机命令，例如：

```text
SHUTDOWNCMD "/sbin/shutdown -h now"
```

脚本的 `upsmon -c fsd` 只负责触发 FSD；真正关闭宿主机的是 `upsmon` 的 `SHUTDOWNCMD`。

---

## 7. 检查 upssched 配置

安装后的 `/etc/nut/upssched.conf` 应包含：

```text
CMDSCRIPT "/etc/nut/upssched.sh"
PIPEFN    /var/run/nut/upssched.pipe
LOCKFN    /var/run/nut/upssched.lock

AT ONBATT * EXECUTE NOTIFY-ONBATT
AT ONBATT * START-TIMER FORCE-FSD 60
AT ONLINE * CANCEL-TIMER FORCE-FSD
AT ONLINE * EXECUTE NOTIFY-ONLINE
AT LOWBATT * EXECUTE NOTIFY-LOWBATT
```

`PIPEFN` 和 `LOCKFN` 所在目录应存在：

```bash
ls -ld /run/nut /var/run/nut
```

在常规 Linux 系统中，`/var/run` 通常指向 `/run`。

不要手工预先创建 `upssched.pipe`。该管道由 `upssched` 自行管理。

---

## 8. 重启 NUT monitor

重新检查配置和脚本：

```bash
sudo bash -n /etc/nut/upssched.sh
sudo visudo -cf /etc/sudoers.d/nut-upssched
sudo -u nut /etc/nut/upssched.sh CHECK
```

然后重启监控服务：

```bash
sudo systemctl restart nut-monitor.service
sudo systemctl status nut-monitor.service --no-pager
```

如果系统没有 `nut-monitor.service`，先查看实际的 NUT 服务名称：

```bash
systemctl list-unit-files 'nut*'
```

查看近期日志：

```bash
sudo journalctl -u nut-monitor.service -n 100 --no-pager
```

查看脚本日志：

```bash
sudo journalctl -t upssched-cmd -n 100 --no-pager
```

实时查看：

```bash
sudo journalctl -f -t upssched-cmd
```

---

## 9. 安全测试

### 9.1 非破坏性测试

运行部署检查：

```bash
sudo -u nut /etc/nut/upssched.sh CHECK
```

测试普通日志事件：

```bash
sudo -u nut /etc/nut/upssched.sh NOTIFY-NOCOMM
sudo -u nut /etc/nut/upssched.sh COMMOK
```

检查日志：

```bash
sudo journalctl -t upssched-cmd -n 20 --no-pager
```

### 9.2 真实断电测试

> 警告：真实断电测试会关闭 VM，并可能关闭 Proxmox VE 宿主机。请在维护窗口执行，并确保具有物理访问或远程电源恢复能力。

测试前确认：

1. BIOS/UEFI 已设置来电自动开机；
2. 需要自动启动的 VM 已配置 Proxmox `Start at boot`；
3. UPS 电池状态正常；
4. NAS 和其他设备的关机时间与 60 秒策略一致；
5. 当前没有 VM 备份、迁移或重要磁盘任务。

建议先测试短时断电：

1. 保持一台测试 VM 正在运行；
2. 断开 UPS 市电输入；
3. 确认 VM 收到优雅关机请求；
4. 在 60 秒内恢复市电；
5. 确认 FSD 被取消，测试 VM 随后恢复启动。

再测试持续断电：

1. 断开 UPS 市电输入并保持超过 60 秒；
2. 确认脚本强制停止仍未关闭的 VM；
3. 确认日志出现“触发 NUT FSD”；
4. 确认 `upsmon` 最终关闭宿主机。

---

## 10. 常见问题

### `sudo: a password is required`

说明 sudoers 没有正确安装，或者脚本实际路径和 sudoers 中的路径不一致。

检查：

```bash
sudo visudo -cf /etc/sudoers.d/nut-upssched
sudo -l -U nut
readlink -f /etc/nut/upssched.sh
```

### `unknown UPS` 或无法读取 UPS 状态

检查 UPS 名称：

```bash
upsc -l 127.0.0.1
```

然后修改脚本中的：

```bash
UPS_TARGET='正确的UPS名称@127.0.0.1'
```

### `qm list` 执行失败

确认当前机器是 Proxmox VE 宿主机，并检查：

```bash
ls -l /usr/sbin/qm
sudo /usr/sbin/qm list
```

### 收到 ONBATT，但脚本没有运行

重点检查 `upsmon.conf`：

```text
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT SYSLOG+EXEC
```

然后查看：

```bash
sudo journalctl -u nut-monitor.service -n 100 --no-pager
```

### 市电恢复后哪些 VM会被启动

脚本不会启动所有 stopped VM，只会处理 `/run/nut/upssched-vms.state` 中记录的 VM，并且要求：

- VM 在断电前处于 running；
- 市电恢复时已经 stopped；
- VM 配置为 `onboot=1`；
- VM 不在 `SPEC_LIST` 中。

未配置 `onboot` 或设置为 `onboot=0` 的 VM不会由脚本恢复。依赖 NAS/NFS 的 VM建议设置 `onboot=0`，待 NAS 准备完成后由外部脚本启动。

如果宿主机已经完成 FSD 并重新启动，VM 是否启动同样取决于 Proxmox 的 `Start at boot` 配置。

### 最终强停时提示 shutdown task 或锁冲突

脚本始终使用：

```bash
qm stop VMID --skiplock true
```

如果当前 Proxmox VE 的 `qm stop` 支持 `--overrule-shutdown`，脚本会自动追加：

```bash
--overrule-shutdown true
```

该检测通过 `qm help stop` 自动完成，无需手工配置。旧版本不支持时会自动回退为仅使用 `--skiplock true`。

### VM 无法在 50 秒内关闭

检查 VM 是否支持 ACPI 关机，以及 Guest Agent/操作系统是否能正常响应关机请求。

也可以适当延长时间，但最终计时必须大于 VM 优雅关机时间。例如：

```bash
# upssched.sh
VM_SHUTDOWN_TIMEOUT=80
```

```text
# upssched.conf
AT ONBATT * START-TIMER FORCE-FSD 90
```

UPS 续航较短时不建议延长。

---

## 11. 更新脚本

更新前备份：

```bash
sudo cp -a /etc/nut/upssched.sh /etc/nut/upssched.sh.bak
sudo cp -a /etc/nut/upssched.conf /etc/nut/upssched.conf.bak
```

安装新版本：

```bash
sudo install -o root -g root -m 0755 \
    upssched.sh /etc/nut/upssched.sh

sudo install -o root -g root -m 0644 \
    upssched.conf /etc/nut/upssched.conf
```

检查并重启：

```bash
sudo bash -n /etc/nut/upssched.sh
sudo -u nut /etc/nut/upssched.sh CHECK
sudo systemctl restart nut-monitor.service
```

---

## 12. 卸载或回滚

停止使用本脚本前，先从 `/etc/nut/upsmon.conf` 中移除相关事件的 `EXEC`，或者将 `NOTIFYCMD` 改回原来的命令，然后重启 NUT monitor。

删除文件：

```bash
sudo rm /etc/nut/upssched.sh
sudo rm /etc/nut/upssched.conf
sudo rm /etc/sudoers.d/nut-upssched
sudo rm -f /run/nut/upssched-vms.state
sudo rm -f /run/nut/upssched-shutdown.deadline
sudo rm -f /run/nut/upssched-action.lock
```

如果之前创建了备份，可以恢复：

```bash
sudo cp -a /etc/nut/upssched.sh.bak /etc/nut/upssched.sh
sudo cp -a /etc/nut/upssched.conf.bak /etc/nut/upssched.conf
```

恢复后重新检查配置并重启 NUT monitor。