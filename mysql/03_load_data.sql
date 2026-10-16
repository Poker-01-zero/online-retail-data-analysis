-- ============================================================
-- 03_load_data.sql
-- 用途：批量导入 106 万行原始数据到原始层表
-- 幂等：可重复执行，结果恒为 1,067,371 行
-- ============================================================
-- 前置条件：
--   数据文件必须位于 MySQL 允许的导入目录（受 secure-file-priv 限制）。
--   本机配置为：C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/
--   若文件不在该目录，请先复制过去；不要去修改 secure-file-priv 配置
--   （那是数据库的安全边界，改了要重启服务且降低安全性）。
-- ============================================================
-- 参数说明（每一项都不可省）：
--   CHARACTER SET utf8mb4       指定文件编码，防止 £ 等字符乱码
--   FIELDS TERMINATED BY ','    字段分隔符
--   OPTIONALLY ENCLOSED BY '"'  ★关键★ 识别引号包裹的字段，
--                               使 "RECORD FRAME 7"" SINGLE SIZE " 这类
--                               内含逗号与转义引号的值不被切错列
--   ESCAPED BY ''               ★关键★ 关闭转义字符处理。
--                               MySQL 默认转义符为 \，会把 PINK\ON STICK
--                               存成 PINKON STICK（丢掉反斜杠），造成静默数据损坏。
--                               置空后严格按 CSV 标准解析。详见 ../数据质量记录.md
--   LINES TERMINATED BY '\n'    行分隔符 —— 经实测本文件为 LF 换行，非 Windows 的 CRLF
--   IGNORE 1 LINES              跳过文件首行表头
-- ============================================================
-- 性能参考：本机 106 万行导入耗时约 5 秒。
--           若改用逐行 INSERT，同规模数据耗时在小时级。
-- ============================================================

USE online_retail;

-- 先清空，保证脚本可重复执行（TRUNCATE 秒级完成且不写逐行日志；
-- 代价是不可回滚，但紧接着就会重新导入）
TRUNCATE TABLE online_retail_raw;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/online_retail_II.csv'
INTO TABLE online_retail_raw
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

-- ------------------------------------------------------------
-- 导入后对账：应返回 1067371
-- 同时检查 Messages 面板的 Records / Deleted / Skipped / Warnings 四项，
-- Warnings 不为 0 说明有字段被静默截断，必须排查。
-- ------------------------------------------------------------
SELECT COUNT(*) AS 导入行数 FROM online_retail_raw;
