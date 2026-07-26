#!/bin/bash
# 启用报错立即退出机制 (建议开启)
set -e

# ================= 配置区域 =================
BACKUP_FILEDIR="/home/"
# 当前日期，格式如：202605131230
DATE=$(date "+%Y%m%d%H%M")
# 保留天数
DEL_DAY=7

# 数据库连接配置
DB_USER="root"
DB_PASS=""
CONTAINER_NAME="mariadb"
# ============================================

# 确保备份目录存在
mkdir -p "${BACKUP_FILEDIR}"

echo "========== 数据库备份开始: $(date) =========="

# 1. 查询所有需要备份的数据库
# 使用 -s 参数静默输出，直接避免出现 + 或 | 这种表格符号
# 使用 MYSQL_PWD 环境变量传密码，避免在 ps 进程中明文暴露
DATABASES=$(docker exec -i -e MYSQL_PWD="${DB_PASS}" ${CONTAINER_NAME} mariadb -u"${DB_USER}" -s -e "SHOW DATABASES;" | grep -Ev "^(Database|sys|information_schema|performance_schema|mysql)$")

for db in $DATABASES; do
    echo "正在备份数据库: ${db} ..."
    
    # 2. 执行备份
    # 替换了 --lock-all-tables 为 --single-transaction (无锁热备)
    # 字符集建议更新为 utf8mb4 兼容性更好
    docker exec -i -e MYSQL_PWD="${DB_PASS}" ${CONTAINER_NAME} mariadb-dump -u"${DB_USER}" \
        --default-character-set=utf8mb4 -q --single-transaction --flush-logs -E -R --triggers -B "${db}" \
        | gzip > "${BACKUP_FILEDIR}/${db}_${DATE}.sql.gz"
        
    echo "完成: ${BACKUP_FILEDIR}/${db}_${DATE}.sql.gz"
done

echo "========== 开始清理 ${DEL_DAY} 天前的历史备份 =========="

# 3. 清理过期备份
# 使用 find 命令一步到位，查找早于 DEL_DAY 天的 .sql.gz 文件并删除
find "${BACKUP_FILEDIR}" -type f -name "*.sql.gz" -mtime +${DEL_DAY} -exec rm -f {} \;
echo "过期备份清理完成"

# 4. 设置合理的权限
echo "正在设置备份文件权限..."
chown -R ene:ene "${BACKUP_FILEDIR}"
# 文件夹给 755 权限
find "${BACKUP_FILEDIR}" -type d -exec chmod 755 {} \;
# 备份文件本身包含敏感数据，应严格限制为 600 (仅所有者可读写)
find "${BACKUP_FILEDIR}" -type f -name "*.sql.gz" -exec chmod 600 {} \;

echo "========== 备份任务全部结束: $(date) =========="