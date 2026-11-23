-- =============================================================================
-- member-C.sql        组员 2 的三个指标：05 / 06 / 09
--   05 工作日/周末客流比        工作日日均客流 ÷ 周末日均客流
--   06 节假日客流变化率         (节假日日均 − 非节假日日均) ÷ 非节假日日均
--   09 月度客流趋势斜率         月日均客流对月份序号做线性回归的斜率
--
-- 数据来源（按 docs/分工方案.md：都用组长放进仓库的那份，谁都不许自己换）
--   data/sample.csv    → 组长用 setup/ 建表，默认表名 sample
--   data/dim_date.csv  → 组长建表，默认表名 dim_date
--
-- 环境不同只需要改下面两行表名，其余不要动。
-- =============================================================================
SET hivevar:sample_table=sample;
SET hivevar:dim_table=dim_date;


-- =============================================================================
-- 第 0 步 · 把两个源表规整成后面三条 SQL 都能用的形状（跑一次即可）
--   规整后：v_c_daily(stat_date, flow) 和 v_c_dim(stat_date, day_type, is_holiday, month_seq)
--   ★ 只有这一步依赖源表字段名，改字段名只改这里 ★
-- =============================================================================

-- 0.1 日客流：sample 里一条记录 = 一次刷卡，按刷卡日期数条数
--     （如果组长的 sample 列名不是 swipe_time，把下面 4 处 swipe_time 换成实际列名）
DROP VIEW IF EXISTS v_c_daily;
CREATE VIEW v_c_daily AS
SELECT
    from_unixtime(unix_timestamp(TRIM(CAST(swipe_time AS STRING))), 'yyyy-MM-dd') AS stat_date,
    COUNT(1) AS flow
FROM ${hivevar:sample_table}
WHERE swipe_time IS NOT NULL
GROUP BY from_unixtime(unix_timestamp(TRIM(CAST(swipe_time AS STRING))), 'yyyy-MM-dd');

-- 0.1 备选：如果 sample 是 MTA 那种「累计计数」表（DATE / TIME / UNIT / SCP / ENTRIES / EXITS），
--      先把 0.1 上面那段注释掉，再取消下面这段的注释（相邻两条相减得到每个区间的增量）
-- DROP VIEW IF EXISTS v_c_daily;
-- CREATE VIEW v_c_daily AS
-- SELECT stat_date, SUM(NVL(d_entries, 0) + NVL(d_exits, 0)) AS flow
-- FROM (
--     SELECT s.stat_date,
--            CASE WHEN s.entries_cum - LAG(s.entries_cum) OVER (PARTITION BY s.unit, s.scp ORDER BY s.stat_date, s.time_str) < 0
--                 THEN 0
--                 ELSE s.entries_cum - LAG(s.entries_cum) OVER (PARTITION BY s.unit, s.scp ORDER BY s.stat_date, s.time_str)
--            END AS d_entries,
--            CASE WHEN s.exits_cum - LAG(s.exits_cum) OVER (PARTITION BY s.unit, s.scp ORDER BY s.stat_date, s.time_str) < 0
--                 THEN 0
--                 ELSE s.exits_cum - LAG(s.exits_cum) OVER (PARTITION BY s.unit, s.scp ORDER BY s.stat_date, s.time_str)
--            END AS d_exits
--     FROM (
--         SELECT CAST(`date` AS STRING)  AS stat_date,
--                CAST(`time` AS STRING)  AS time_str,
--                unit, scp,
--                CAST(entries AS BIGINT) AS entries_cum,
--                CAST(exits   AS BIGINT) AS exits_cum
--         FROM ${hivevar:sample_table}
--     ) s
-- ) t
-- GROUP BY stat_date;

-- 0.2 日历：只认两列（日期、是否节假日），day_type 在这里统一推，后面三条 SQL 不再各自判断
--     判定顺序：先看节假日 → 再看星期几；周末一律 WEEKEND，周一到周五一律 WORKDAY
--     （组长的 dim_date 列名不同，就改下面 date / is_holiday 两处）
DROP VIEW IF EXISTS v_c_dim;
CREATE VIEW v_c_dim AS
SELECT
    CAST(`date` AS STRING)                                   AS stat_date,
    CAST(is_holiday AS INT)                                  AS is_holiday,
    CASE WHEN CAST(is_holiday AS INT) = 1                THEN 'HOLIDAY'
         WHEN pmod(dayofweek(CAST(`date` AS STRING)) + 5, 7) + 1 >= 6 THEN 'WEEKEND'
         ELSE 'WORKDAY'
    END                                                       AS day_type,
    YEAR(CAST(`date` AS STRING)) * 12 + MONTH(CAST(`date` AS STRING)) AS month_seq
FROM ${hivevar:dim_table};


-- =============================================================================
-- 指标 05 · 工作日/周末客流比
--   算的是：平时（工作日）一天的人流，是周末的几倍。
--   口径：节假日两边都不算（元旦/圣诞这种落在周中的假日会把工作日日均拉低）
-- =============================================================================
SELECT
    '05'                          AS metric_id,
    '工作日/周末客流比'             AS metric_name,
    'ALL'                         AS dim_key,
    ROUND(AVG(CASE WHEN day_type = 'WORKDAY' THEN flow END)
        / AVG(CASE WHEN day_type = 'WEEKEND' THEN flow END), 4) AS value,
    'ratio'                       AS unit
FROM (
    SELECT f.stat_date, f.flow, d.day_type
    FROM v_c_daily f
    JOIN v_c_dim d ON f.stat_date = d.stat_date
    WHERE d.day_type IN ('WORKDAY', 'WEEKEND')
) t;


-- =============================================================================
-- 指标 06 · 节假日客流变化率
--   算的是：节假日比平时少（多）了百分之几。
--   口径：非节假日 = 所有不是节假日的日子，包含普通周末（这样基数才是「平常日子」）
-- =============================================================================
SELECT
    '06'                          AS metric_id,
    '节假日客流变化率'              AS metric_name,
    'ALL'                         AS dim_key,
    ROUND((AVG(CASE WHEN is_holiday = 1 THEN flow END)
         - AVG(CASE WHEN is_holiday = 0 THEN flow END))
        / AVG(CASE WHEN is_holiday = 0 THEN flow END), 4) AS value,
    'ratio'                       AS unit
FROM (
    SELECT f.stat_date, f.flow, d.is_holiday
    FROM v_c_daily f
    JOIN v_c_dim d ON f.stat_date = d.stat_date
) t;


-- =============================================================================
-- 指标 09 · 月度客流趋势斜率
--   算的是：平均每个月日客流涨（跌）多少人次，正数=越往后人越多。
--   算法：最小二乘 slope = (n·Σxy − Σx·Σy) ÷ (n·Σx² − (Σx)²)，x = month_seq，y = 该月日均客流
-- =============================================================================
SELECT
    '09'                          AS metric_id,
    '月度客流趋势斜率'              AS metric_name,
    'ALL'                         AS dim_key,
    ROUND((n * sxy - sx * sy) / (n * sxx - sx * sx), 4) AS value,
    '人次/月'                      AS unit
FROM (
    SELECT COUNT(1)                   AS n,
           SUM(month_seq)             AS sx,
           SUM(avg_flow)              AS sy,
           SUM(month_seq * avg_flow)  AS sxy,
           SUM(month_seq * month_seq) AS sxx
    FROM (
        SELECT d.month_seq AS month_seq, AVG(d.flow) AS avg_flow
        FROM (
            SELECT f.stat_date, f.flow, dd.month_seq
            FROM v_c_daily f
            JOIN v_c_dim dd ON f.stat_date = dd.stat_date
        ) d
        GROUP BY d.month_seq
    ) m
) fit;


-- =============================================================================
-- 出结果：三条 SQL 跑完，按 output/README.md 的表头各存一个 CSV（UTF-8，4 位小数）
--   hive -e "...指标05那条..." > output/metric_05.csv  ← 前面补一行表头
-- 表头： metric_id,metric_name,dim_key,value,unit
-- 本月明细（答辩画图用，可选）：把 09 那条的 m 子查询单独 select 出来即可
-- =============================================================================
