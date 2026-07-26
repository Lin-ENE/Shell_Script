#!/bin/bash

# Transmission远程地址和端口
REMOTE_HOST="localhost"
REMOTE_PORT="9091"

# 如果设置了用户名和密码，请填写
USERNAME=""
PASSWORD=""

# 目标域名
TARGET_DOMAIN="tracker.yourdomain.com"

# 构建认证参数
if [[ -n $USERNAME && -n $PASSWORD ]]; then
    AUTH="--auth $USERNAME:$PASSWORD"
else
    AUTH=""
fi

# 获取所有种子的ID列表
TORRENT_IDS=$(transmission-remote "$REMOTE_HOST:$REMOTE_PORT" $AUTH -l | awk 'NR>1 {print $1}' | tr -d '*' | grep -E '^[0-9]+$')

# 遍历每个种子
for ID in $TORRENT_IDS; do
    # 获取种子的磁力链接并提取tracker信息
    MAGNET_LINK=$(transmission-remote "$REMOTE_HOST:$REMOTE_PORT" $AUTH -t "$ID" --info | grep 'Magnet:' | sed 's/^.*Magnet://')

    # 解码磁力链接
    DECODED_MAGNET=$(printf '%b' "${MAGNET_LINK//%/\\x}")

    # 提取tracker地址
    TRACKERS=$(echo "$DECODED_MAGNET" | grep -oE '(&tr=)[^&]+' | sed 's/&tr=//g' | grep "$TARGET_DOMAIN")

    # 对每个tracker进行替换
    for TRACKER in $TRACKERS; do
        # 构建新的tracker地址
        NEW_TRACKER="${TRACKER/http:/https:}"

        echo "种子ID $ID: 将 $TRACKER 替换为 $NEW_TRACKER"

        # 删除旧的tracker
        transmission-remote "$REMOTE_HOST:$REMOTE_PORT" $AUTH -t "$ID" --tracker-remove "$TRACKER"

        # 添加新的tracker
        transmission-remote "$REMOTE_HOST:$REMOTE_PORT" $AUTH -t "$ID" --tracker-add "$NEW_TRACKER"
    done
done
