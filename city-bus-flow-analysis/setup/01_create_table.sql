-- ============================================================
-- 只需要【组长】做一次，其他三个人不用管这个文件
-- 作用：把 CSV 变成 Hive 里可以查询的表
-- ============================================================
-- 第 1 步：先在终端执行这 3 行（把两个 CSV 放进 HDFS）
--   hdfs dfs -mkdir -p /transit/ods_card /transit/dim_date
--   hdfs dfs -put -f data/sample.csv /transit/ods_card/
--   hdfs dfs -put -f data/dim_date.csv /transit/dim_date/
-- 第 2 步：执行本文件
--   beeline -u jdbc:hive2://localhost:10000 -f setup/01_create_table.sql
-- 说明：换成真实数据时，只需重新 put 两个 CSV，字段名不一致就改下面的表结构
-- ============================================================

CREATE DATABASE IF NOT EXISTS transit;
USE transit;

DROP TABLE IF EXISTS ods_card;
CREATE EXTERNAL TABLE ods_card (
  card_id     STRING,
  trade_time  STRING,
  line_name   STRING,
  station     STRING,
  in_out      STRING,
  counter     INT
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '/transit/ods_card'
TBLPROPERTIES ("skip.header.line.count"="1");

DROP TABLE IF EXISTS dim_date;
CREATE EXTERNAL TABLE dim_date (
  dt          STRING,
  is_workday  INT,
  is_weekend  INT,
  is_holiday  INT,
  month_seq   INT,
  ym          STRING
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION '/transit/dim_date'
TBLPROPERTIES ("skip.header.line.count"="1");

-- 清洗视图：从时间里拆出「日期」和「小时」，后面所有指标都查它
DROP VIEW IF EXISTS dwd_card;
CREATE VIEW dwd_card AS
SELECT card_id,
       substr(trade_time, 1, 10)            AS dt,
       CAST(substr(trade_time, 12, 2) AS INT) AS hh,
       line_name, station, in_out, counter, trade_time
FROM ods_card
WHERE length(trade_time) >= 19;

-- 两个公用分母，省得每个人自己算
DROP VIEW IF EXISTS v_days;
CREATE VIEW v_days AS SELECT COUNT(DISTINCT dt) AS days FROM dwd_card;

DROP VIEW IF EXISTS v_total;
CREATE VIEW v_total AS SELECT COUNT(*) AS total FROM dwd_card;

-- 检查是否成功：应该看到 4561 和 89
SELECT '数据总条数' AS item, COUNT(*) AS num FROM dwd_card;
SELECT '统计天数' AS item, COUNT(DISTINCT dt) AS num FROM dwd_card;
