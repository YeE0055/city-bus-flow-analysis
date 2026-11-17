每人交 3 个结果文件，按自己的指标编号命名，例如 `metric_01.csv`。

UTF-8 CSV，第一行表头固定：

```
metric_id,metric_name,dim_key,value,unit
```

数值保留 4 位小数；一个指标有多行时，`dim_key` 写线路名 / 站点名等维度值。
