-- =====================================================================
-- sql/member-D.sql  ——  组员 3：指标 10 / 11 / 12
-- 运行：beeline -u jdbc:hive2://<主机>:10000/transit -f sql/member-D.sql
--
-- 依赖 setup/01_create_table.sql 建好的：
--   transit.ods_card   原始刷卡表（card_id, trade_time, line_name, station, in_out, counter）
--   transit.dim_date   日历表（dt, is_workday, is_weekend, is_holiday, month_seq, ym）
--   transit.dwd_card   组长建好的清洗视图（已把 trade_time 拆成 dt / hh）
-- 约定：in_out 取值为 'IN'（进站）/ 'OUT'（出站）；
--       1 条刷卡记录 = 1 人次，进站出站都算，不按卡号去重。
--       以下三条 SQL 各自独立、都能单独重跑，不依赖别人产出的中间表。
-- =====================================================================


-- ---------------------------------------------------------------------
-- 指标 10  站点进出比 = SUM(出站客流) / SUM(进站客流)
--   在统计期内按站点名整体聚合（同名站合并），出站条数除以进站条数。
--   比值 > 1：出站的人比进站多，偏上班 / 商业型站点；
--   比值 < 1：进站的人比出站多，偏居住型站点。
--   分母用 NULLIF 兜底：某站只有出站没有进站时返回空值，而不是除零报错。
-- ---------------------------------------------------------------------
SELECT
  '10'                                                        AS metric_id,
  '站点进出比'                                                 AS metric_name,
  station                                                     AS dim_key,
  CAST(ROUND(
         CAST(SUM(IF(in_out = 'OUT', 1, 0)) AS DOUBLE)
         / NULLIF(SUM(IF(in_out = 'IN', 1, 0)), 0)
       , 4) AS DECIMAL(20, 4))                                AS `value`,
  'ratio'                                                     AS unit
FROM transit.dwd_card
GROUP BY station
ORDER BY station;


-- ---------------------------------------------------------------------
-- 指标 11  工作日客流稳定性 = STD(工作日日客流) / MEAN(工作日日客流)
--   先按天汇总全网客流，再只保留 dim_date.is_workday = 1 的日子
--   （含调休上班的周末，不含法定节假日），算变异系数：越小越稳。
--   标准差用 STDDEV_POP（总体标准差）：Hive 里 std() / stddev() / stddev_pop()
--   是同一个函数，算的都是总体标准差，所以按口径里的「STD」直译就是这个。
--   若全组约定用样本标准差，把 STDDEV_POP 换成 STDDEV_SAMP 即可，其余不变。
--   结果只有一个数，dim_key 记 'ALL'。
-- ---------------------------------------------------------------------
WITH daily_flow AS (
  SELECT dt,
         COUNT(1) AS flow
  FROM transit.dwd_card
  GROUP BY dt
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
  'ratio'                                                     AS unit
FROM workday_flow;


-- ---------------------------------------------------------------------
-- 指标 12  累计计数异常率 = (差分负值数 + 重复记录数) / 总差分记录数
--   同一张卡的记录按 卡号 + 刷卡时间 排序，相邻两条 counter 相减：
--     差值 < 0 → 计数回退，异常；
--     差值 = 0 → 计数没涨（同一笔被重复记录 / 计数没递增），异常。
--   分母 = 有前一条记录的差分条数 = 总记录数 - 卡号去重数。
--   用 ROW_NUMBER 标出每张卡的第一条再筛掉，比用 prev_counter IS NOT NULL 更准：
--   万一 counter 是空值，那一行也不会被误删，分母仍然对得上。
--   ORDER BY 里多带一个 counter，是为了同一秒有多条时排序稳定、结果可复现
--   （对整行完全重复的记录没有影响）。
--   结果只有一个数，dim_key 记 'ALL'。
-- ---------------------------------------------------------------------
WITH ordered AS (
  SELECT card_id,
         trade_time,
         counter,
         LAG(counter) OVER (
           PARTITION BY card_id
           ORDER BY trade_time, counter
         ) AS prev_counter,
         ROW_NUMBER() OVER (
           PARTITION BY card_id
           ORDER BY trade_time, counter
         ) AS rn
  FROM transit.dwd_card
),
diffed AS (
  SELECT counter - prev_counter AS diff_count
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
  'ratio'                                                     AS unit
FROM diffed;
