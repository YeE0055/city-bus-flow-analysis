-- =====================================================================
-- sql/member-C.sql  ——  组员 2：指标 05 / 06 / 09
-- 运行：beeline -u jdbc:hive2://<主机>:10000/transit -f sql/member-C.sql
--
-- 依赖：setup/01_create_table.sql 建好的 transit.ods_card / transit.dim_date
--       以及清洗视图 transit.dwd_card（含 dt、hh、station、line_name、in_out、counter）
-- 口径：1 条刷卡记录 = 1 人次（进站、出站都算，不按卡号去重）；
--       日期标签一律查 dim_date，不按星期几硬判：
--         工作日 = is_workday = 1（含调休上班的周末）
--         周末   = is_weekend = 1 且 is_holiday = 0
--         节假日 = is_holiday = 1
--         非节假日 = is_holiday = 0 的所有日子（含普通周末）
-- =====================================================================

USE transit;


-- ---------------------------------------------------------------------
-- 指标 05  工作日/周末客流比 = 工作日日均客流 / 周末日均客流
--   先按天汇总全网客流，再按 dim_date 的标签分成两组求平均，最后相除。
--   节假日两边都不进：元旦、春节这类落在周中的假日会把工作日日均拉低，
--   落在周末的假日会把周末日均拉低，剔掉后才是纯粹的「通勤 vs 休闲」对比。
--   结果 > 1 说明工作日客流更高，城市以通勤出行为主。
--
--   【口径补丁，必须看】README 口径第 3 条写的是「周末 = is_weekend=1 且 is_holiday=0」，
--   但 dim_date 里有 2 个调休上班日（2026-02-28 周六、2026-04-26 周日）同时满足
--   is_weekend=1、is_holiday=0、is_workday=1，按字面会被同时算进工作日和周末，重复计数。
--   这两天的实际客流是 52 和 68 人次，和周末（32–42）明显不是一个量级、反而贴近工作日。
--   因此这里给周末条件补一条 is_workday = 0，把调休日从周末里剔除。
--   两种口径的结果：排除调休 05 = 1.6545（本文件采用）；不排除 05 = 1.5591。
--   若组长坚持按字面口径，把下面 is_workday = 0 这个条件删掉即可。
-- ---------------------------------------------------------------------
WITH daily_flow AS (
  SELECT c.dt,
         COUNT(1)            AS flow,
         MAX(c.is_workday)   AS is_workday,
         MAX(c.is_weekend)   AS is_weekend,
         MAX(c.is_holiday)   AS is_holiday
  FROM transit.dwd_card d
  JOIN transit.dim_date c
    ON c.dt = d.dt
  GROUP BY c.dt
)
SELECT
  '05'                                                              AS metric_id,
  '工作日/周末客流比'                                                 AS metric_name,
  'ALL'                                                             AS dim_key,
  CAST(ROUND(
         AVG(IF(is_workday = 1, flow, NULL))
         / AVG(IF(is_weekend = 1 AND is_holiday = 0 AND is_workday = 0, flow, NULL))
       , 4) AS DECIMAL(20, 4))                                      AS `value`,
  '比值'                                                            AS unit
FROM daily_flow;


-- ---------------------------------------------------------------------
-- 指标 06  节假日客流变化率 = (节假日日均 - 非节假日日均) / 非节假日日均
--   分子分母都按天算日均，不等权：节假日只有几天也不会被其余日子稀释。
--   非节假日含普通周末（README 口径第 3 条），否则基数变成纯工作日，
--   节假日的降幅会被夸大，而且和工作日/周末比算的是同一件事。
--   结果一般为负，绝对值越大说明节假日出行越少。
-- ---------------------------------------------------------------------
WITH daily_flow AS (
  SELECT c.dt,
         COUNT(1)          AS flow,
         MAX(c.is_holiday) AS is_holiday
  FROM transit.dwd_card d
  JOIN transit.dim_date c
    ON c.dt = d.dt
  GROUP BY c.dt
)
SELECT
  '06'                                                              AS metric_id,
  '节假日客流变化率'                                                   AS metric_name,
  'ALL'                                                             AS dim_key,
  CAST(ROUND(
         (AVG(IF(is_holiday = 1, flow, NULL)) - AVG(IF(is_holiday = 0, flow, NULL)))
         / AVG(IF(is_holiday = 0, flow, NULL))
       , 4) AS DECIMAL(20, 4))                                      AS `value`,
  '比例'                                                            AS unit
FROM daily_flow;


-- ---------------------------------------------------------------------
-- 指标 09  月度客流趋势斜率
--   以「月」为样本做一元线性回归：x = dim_date.month_seq（1、2、3…），
--   y = 该月日均客流（月内各日客流之和 ÷ 月内有效天数）。
--   slope = (n·Σxy − Σx·Σy) ÷ (n·Σx² − (Σx)²)
--   用最小二乘而不是「首末月差 ÷ 间隔月数」：只用两个点的话，
--   某个月一次设备故障或一场暴雨就能把斜率带偏。
--   单位人次/月，正数=客流逐月上升。
--   数据不足两个月时分母为 0，返回空值（无法拟合，不是算错）。
-- ---------------------------------------------------------------------
WITH daily_flow AS (
  SELECT c.dt,
         MAX(c.month_seq) AS month_seq,
         COUNT(1)         AS flow
  FROM transit.dwd_card d
  JOIN transit.dim_date c
    ON c.dt = d.dt
  GROUP BY c.dt
),
monthly AS (
  SELECT month_seq,
         AVG(flow) AS avg_flow,
         COUNT(1)  AS days
  FROM daily_flow
  GROUP BY month_seq
),
fit AS (
  SELECT COUNT(1)                   AS n,
         SUM(month_seq)             AS sx,
         SUM(avg_flow)              AS sy,
         SUM(month_seq * avg_flow)  AS sxy,
         SUM(month_seq * month_seq) AS sxx
  FROM monthly
)
SELECT
  '09'                                                              AS metric_id,
  '月度客流趋势斜率'                                                   AS metric_name,
  'ALL'                                                             AS dim_key,
  CAST(ROUND((n * sxy - sx * sy) / (n * sxx - sx * sx), 4)
       AS DECIMAL(20, 4))                                           AS `value`,
  '人次/月'                                                          AS unit
FROM fit;


-- ---------------------------------------------------------------------
-- 附：指标 09 的月度序列，写报告画趋势图、手工核对斜率时用（不是交付文件）
-- ---------------------------------------------------------------------
WITH daily_flow AS (
  SELECT c.dt,
         MAX(c.month_seq) AS month_seq,
         MAX(c.ym)        AS ym,
         COUNT(1)         AS flow
  FROM transit.dwd_card d
  JOIN transit.dim_date c
    ON c.dt = d.dt
  GROUP BY c.dt
)
SELECT month_seq,
       MAX(ym)       AS ym,
       COUNT(1)      AS days,
       ROUND(AVG(flow), 2) AS avg_flow
FROM daily_flow
GROUP BY month_seq
ORDER BY month_seq;
