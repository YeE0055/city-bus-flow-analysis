-- ============================================================
-- 组长（成员 A）负责：01 日均刷卡量、02 高峰小时系数、08 早晚高峰客流比
-- 三条 SQL，一条算一个题；输出统一 5 列
-- 前提：组长已经执行过 setup/01_create_table.sql
-- 跑法：beeline -u jdbc:hive2://localhost:10000/transit -f sql/member-A.sql
-- 跑出的 3 个数分别存进 output/metric_01.csv、metric_02.csv、metric_08.csv
-- ============================================================

USE transit;

-- 01 日均刷卡量 = 总刷卡条数 / 有刷卡记录的不同日期数
SELECT '01' AS metric_id, '日均刷卡量' AS metric_name, '全网' AS dim_key,
       ROUND(COUNT(*) / MAX(d.days), 4) AS value, '人次/天' AS unit
FROM dwd_card CROSS JOIN v_days d;

-- 02 高峰小时系数 = 当天最挤那一小时的客流 / 当天总客流，再对所有天取平均
WITH h AS (
  SELECT dt, hh, COUNT(*) AS c FROM dwd_card GROUP BY dt, hh
),
p AS (
  SELECT dt, MAX(c) AS peak FROM h GROUP BY dt
),
t AS (
  SELECT dt, SUM(c) AS total FROM h GROUP BY dt
)
SELECT '02', '高峰小时系数', '全网',
       ROUND(AVG(p.peak / t.total), 4), '比例'
FROM p JOIN t ON p.dt = t.dt;

-- 08 早晚高峰客流比 = 早高峰客流 / 晚高峰客流
-- 早高峰 7:00-9:00 即 7、8 点；晚高峰 17:00-19:00 即 17、18 点
SELECT '08', '早晚高峰客流比', '全网',
       ROUND(SUM(CASE WHEN hh IN (7, 8) THEN 1 ELSE 0 END)
           / SUM(CASE WHEN hh IN (17, 18) THEN 1 ELSE 0 END), 4), '比例'
FROM dwd_card;
