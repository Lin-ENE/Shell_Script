#!/bin/bash
## 先解压并直接通过管道导入 postgres
#gunzip -c /home/docker/postgres/backup/lobechat_202605131230.sql.gz | docker exec -i postgres psql -U ENE -d lobechat
# 启用报错立即退出机制
set -e

# ================= 配置区域 =================
BACKUP_FILEDIR="/home/"
# 当前日期，格式如：202605131230
DATE=$(date "+%Y%m%d%H%M")
# 保留天数
DEL_DAY=7

# 数据库连接配置
DB_USER="admin"
# 如果你需要密码才能备份，请在这里填入密码。如果已经配了强信赖/免密，留空即可
DB_PASS="" 
CONTAINER_NAME="postgres"
DB_HOST="127.0.0.1"
DB_PORT="5432"

# 需要备份的数据库列表 (如果有新增，直接加在这个数组里即可)
DATABASES=("lobechat" "logto")
# ============================================

# 确保备份目录存在
mkdir -p "${BACKUP_FILEDIR}"

echo "========== PostgreSQL 数据库备份开始: $(date) =========="

# 遍历数组进行备份
for db in "${DATABASES[@]}"; do
    echo "正在备份数据库: ${db} ..."
    
    # 删除了无效参数 -q
    # 同时保留了 --no-password，并确保输出正确重定向
    docker exec -i -e PGPASSWORD="${DB_PASS}" ${CONTAINER_NAME} \
        pg_dump --host "${DB_HOST}" --port "${DB_PORT}" --username "${DB_USER}" \
        --no-password --format=p --blobs "${db}" \
        | gzip > "${BACKUP_FILEDIR}/${db}_${DATE}.sql.gz"
        
    # 检查上一个管道命令是否成功
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo "成功: ${BACKUP_FILEDIR}/${db}_${DATE}.sql.gz"
    else
        echo "错误: 数据库 ${db} 备份失败！"
        rm -f "${BACKUP_FILEDIR}/${db}_${DATE}.sql.gz"
    fi
done

echo "========== 开始清理 ${DEL_DAY} 天前的历史备份 =========="

# 使用 find 命令一步到位清理过期备份
find "${BACKUP_FILEDIR}" -type f -name "*.sql.gz" -mtime +${DEL_DAY} -exec rm -f {} \;
echo "过期备份清理完成"

# 设置合理的权限
echo "正在设置备份文件权限..."
chown -R ene:ene "${BACKUP_FILEDIR}"
# 文件夹给 755 权限
find "${BACKUP_FILEDIR}" -type d -exec chmod 755 {} \;
# 备份文件包含敏感数据，严格限制为 600
find "${BACKUP_FILEDIR}" -type f -name "*.sql.gz" -exec chmod 600 {} \;

echo "========== 备份任务全部结束: $(date) =========="