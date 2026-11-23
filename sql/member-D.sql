-- =====================================================================
-- sql/member-D.sql  ——  组员 3：指标 10 / 11 / 12
-- 运行：beeline -u jdbc:hive2://<主机>:10000/transit -f sql/member-D.sql
--
-- 依赖：setup/01_create_tables.sql 建好的 transit.bus_swipe / transit.dim_date
-- 约定：本文件三条 SQL 各自独立、都能单独重跑，不依赖别人产出的中间表，
--       避免「谁先跑谁后跑」互相影响。
-- 口径：1 条刷卡记录 = 1 人次（进站、出站都算，不按卡号去重）；
--       日期取 swipe_time 前 10 位；日期标签一律查 dim_date，不按星期几硬判。
-- =====================================================================


-- ---------------------------------------------------------------------
-- 指标 10  站点进出比 = SUM(出站客流) / SUM(进站客流)
--   在统计期内按站点名整体聚合（同名站合并），出站条数除以进站条数。
--   比值 > 1 说明该站「出站的人比进站的多」，即上班/商业型站点；
--   比值 < 1 说明进站的人多，即居住型站点。
--   分母用 NULLIF 兜底：万一某站只有出站、没有进站，返回空值而不是除零报错。
-- ---------------------------------------------------------------------
SELECT
  '10'                                                        AS metric_id,
  '站点进出比'                                                 AS metric_name,
  station                                                     AS dim_key,
  CAST(ROUND(
         CAST(SUM(IF(in_out = '出站', 1, 0)) AS DOUBLE)
         / NULLIF(SUM(IF(in_out = '进站', 1, 0)), 0)
       , 4) AS DECIMAL(20, 4))                                AS `value`,
  '比值'                                                      AS unit
FROM transit.bus_swipe
GROUP BY station
ORDER BY station;


-- ---------------------------------------------------------------------
-- 指标 11  工作日客流稳定性 = STD(工作日日客流) / MEAN(工作日日客流)
--   先按天汇总全网客流，再只保留 dim_date.is_workday = 1 的日子
--   （含调休上班的周末，不含法定节假日）。
--   标准差取 STDDEV_POP（总体标准差）。Hive 3.1.3 里 std() / stddev() / stddev_pop()
--   是同一个函数，算的都是总体标准差；只有 stddev_samp 才是样本标准差。
--   如果全组约定用样本标准差，把 STDDEV_POP 换成 STDDEV_SAMP 即可，其余不变。
--   结果只有一个数，dim_key 记 'ALL'。
-- ---------------------------------------------------------------------
WITH daily_flow AS (
  SELECT SUBSTR(swipe_time, 1, 10) AS dt,
         COUNT(1)                  AS flow
  FROM transit.bus_swipe
  GROUP BY SUBSTR(swipe_time, 1, 10)
),
workday_flow AS (
  SELECT d.flow
  FROM daily_flow d
  JOIN transit.dim_date c
    ON c.dt = d.dt
  WHERE c.is_workday = 1
)
SELECT
  '11'                                                        AS metric_id,
  '工作日客流稳定性'                                            AS metric_name,
  'ALL'                                                       AS dim_key,
  CAST(ROUND(STDDEV_POP(flow) / AVG(flow), 4) AS DECIMAL(20, 4)) AS `value`,
  '比值'                                                      AS unit
FROM workday_flow;


-- ---------------------------------------------------------------------
-- 指标 12  累计计数异常率 = (差分负值数 + 重复记录数) / 总差分记录数
--   同一张卡的记录按 卡号 + 刷卡时间 排序，相邻两条累计计数相减：
--     差值 < 0 → 计数回退，异常；
--     差值 = 0 → 计数没涨（同一笔被重复记录），异常。
--   分母 = 有前一条记录的差分条数 = 总记录数 - 卡号去重数。
--   用 ROW_NUMBER 标出每张卡的第一条再筛掉，比用 prev_count IS NOT NULL 更准：
--   万一累计计数是空值，那一行也不会被误删，分母仍然对得上。
--   ORDER BY 里多带一个 cumulative_count，是为了同一时间有多条时排序稳定、
--   结果可复现（对完全重复的整行没有影响）。代价是同一秒内的计数回退会被排成
--   「先小后大」，可能少算 1 条负差分；正式数据如果在意这一点，把次序键改回
--   只剩 swipe_time，再另加一个稳定的行号即可。
--   结果只有一个数，dim_key 记 'ALL'。
-- ---------------------------------------------------------------------
WITH ordered AS (
  SELECT card_id,
         swipe_time,
         cumulative_count,
         LAG(cumulative_count) OVER (
           PARTITION BY card_id
           ORDER BY swipe_time, cumulative_count
         ) AS prev_count,
         ROW_NUMBER() OVER (
           PARTITION BY card_id
           ORDER BY swipe_time, cumulative_count
         ) AS rn
  FROM transit.bus_swipe
),
diffed AS (
  SELECT cumulative_count - prev_count AS diff_count
  FROM ordered
  WHERE rn > 1
)
SELECT
  '12'                                                        AS metric_id,
  '累计计数异常率'                                              AS metric_name,
  'ALL'                                                       AS dim_key,
  CAST(ROUND(
         CAST(SUM(IF(diff_count <= 0, 1, 0)) AS DOUBLE) / COUNT(1)
       , 4) AS DECIMAL(20, 4))                                AS `value`,
  '比例'                                                      AS unit
FROM diffed;
