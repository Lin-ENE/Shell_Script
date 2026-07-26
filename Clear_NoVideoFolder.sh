#!/bin/bash

# ==================== 配置区域 ====================
# 目标根目录 A（支持任意深度的绝对路径）
TARGET_DIR="/path"

# 是否为测试模式：true 为模拟运行（只打印不删除），false 为正式删除
DRY_RUN=true
# ==================================================

if [ ! -d "$TARGET_DIR" ]; then
    echo "错误: 目标目录 $TARGET_DIR 不存在！"
    exit 1
fi

echo "开始扫描目录: $TARGET_DIR"
if [ "$DRY_RUN" = true ]; then
    echo "--- 当前为【测试模式】，不会真正删除文件 ---"
fi
echo "------------------------------------------------"

# 创建临时文件
ALL_VIDEO_DIRS=$(mktemp)
WHITE_LIST=$(mktemp)

# 1. 找出所有【直接包含视频】的文件夹路径
# 原生 find 匹配，多后缀直接用 -o (OR) 连接，避开变量解析错误
find "$TARGET_DIR" -type f \( \
    -iname "*.mp4" -o \
    -iname "*.mkv" -o \
    -iname "*.avi" -o \
    -iname "*.mov" -o \
    -iname "*.flv" -o \
    -iname "*.wmv" -o \
    -iname "*.rmvb" -o \
    -iname "*.iso" -o \
    -iname "*.ts" \
\) 2>/dev/null | while read -r video_file; do
    dirname "$video_file" >> "$ALL_VIDEO_DIRS"
done

# 2. 向上追溯，把包含视频的目录、以及它往上的所有父目录，全部加进白名单
if [ -s "$ALL_VIDEO_DIRS" ]; then
    sort -u "$ALL_VIDEO_DIRS" | while read -r v_dir; do
        while [ "$v_dir" != "$TARGET_DIR" ] && [ "$v_dir" != "/" ]; do
            echo "$v_dir" >> "$WHITE_LIST"
            v_dir=$(dirname "$v_dir")
        done
    done
    sort -u "$WHITE_LIST" -o "$WHITE_LIST"
fi

# 3. 精准定位作品主目录（TARGET_DIR 下的第 2 层：演员名/作品名/）
find "$TARGET_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | while read -r album_dir; do
    
    # 检查这个作品目录是否在白名单中
    if ! grep -F -x -q "$album_dir" "$WHITE_LIST"; then
        # 如果不在白名单中，说明该作品目录及其下面所有子目录（包括 extrafanart 等），都没有任何视频
        if [ "$DRY_RUN" = true ]; then
            echo "[将要删除作品目录] $album_dir"
        else
            echo "[正在删除作品目录] $album_dir"
            rm -rf "$album_dir"
        fi
    fi
done
echo "[正在删除空目录]"
find . -type d -empty -delete

# 清理临时文件
rm -f "$ALL_VIDEO_DIRS" "$WHITE_LIST"

echo "------------------------------------------------"
echo "扫描完成！"
if [ "$DRY_RUN" = true ]; then
    echo "提示: 确认列表无误后，将 DRY_RUN=true 改为 false 即可真正整包删除。"
fi
