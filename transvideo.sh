#!/bin/bash

export LANG=C.UTF-8
export LC_ALL=C.UTF-8


EXTENSIONS=("mp4" "mkv" "mov" "avi" "flv" "webm")
LOGFILE="./transcode.log"

for ext in "${EXTENSIONS[@]}"; do
  find . -type f -iname "*.${ext}" | while read -r input; do
    dir=$(dirname "$input")
    base=$(basename "$input")
    name="${base%.*}"
    output="${dir}/${name}-change.mkv"

    # 如果输出文件已存在，则跳过
    if [ -f "$output" ]; then
      echo "⏭️ 已存在，跳过: $output"
      continue
    fi

    echo "🔄 正在转码: $input → $output"

    # 检测分辨率
    resolution=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,pix_fmt \
      -of csv=p=0 "$input")

    width=$(echo "$resolution" | cut -d',' -f1)
    height=$(echo "$resolution" | cut -d',' -f2)
    pix_fmt=$(echo "$resolution" | cut -d',' -f3)

    # 构建滤镜
    filters=()
    if [ -n "$width" ] && [ -n "$height" ]; then
      if [ "$width" -gt 1920 ] || [ "$height" -gt 1080 ]; then
        filters+=("scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease")
      fi
    fi

    case "$pix_fmt" in
      yuvj*|yuv444p|yuv422p) filters+=("format=yuv420p") ;;
      yuv420p10le) filters+=("format=yuv420p10le") ;;
    esac

    vf=$(IFS=','; echo "${filters[*]}")

    ffmpeg -nostdin -hide_banner -y -i "$input" \
      -map 0:v -map 0:a -map 0:s? -map_chapters 0 -map_metadata -1 \
      -map -0:v:m:attached_pic \
      ${vf:+-vf "$vf"} \
      -c:v hevc_nvenc -rc constqp -qp 28 -preset p7 \
      -fps_mode cfr \
      -c:a libopus -b:a 128k -vbr on -ar 48000 \
      -c:s copy \
      -f matroska "$output" >>"$LOGFILE" 2>&1

    if [ $? -eq 0 ]; then
      echo "✅ 完成: $output"
    else
      echo "❌ 出错: $input，详情见 $LOGFILE"
    fi
  done
done

echo "🎉 所有视频处理完成！"
