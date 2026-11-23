#!/usr/bin/env bash
# 组长专用：等 4 个人把 12 个结果 CSV 交齐后，运行一次，拼成 result.csv
# 用法：bash scripts/run_all.sh
# 不需要 Hive，普通终端就能跑

cd "$(dirname "$0")/.." || exit 1
OUT="result.csv"

printf 'metric_id,metric_name,dim_key,value,unit\n' > "$OUT"

n=0
for f in output/metric_*.csv; do
  [ -f "$f" ] || continue
  tail -n +2 "$f" | tr -d '\r' | grep -E '^[0-9]{2},' >> "$OUT"
  n=$((n + 1))
done

got=$(tail -n +2 "$OUT" | cut -d, -f1 | sort -u | wc -l | tr -d ' ')
echo "已合并 $n 个结果文件 → $OUT"
echo "指标进度：$got / 12"
if [ "$got" -lt 12 ]; then
  echo "还没收齐，等组员交完再跑一次。"
else
  echo "12 个指标齐了。双击 dashboard/index.html，选择 result.csv 查看。"
fi
