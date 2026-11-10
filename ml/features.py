"""特征与标签。

两段内容：
    1. load_data() —— 把原始 CSV 清洗成销售明细 + 取消明细两张表
    2. build_dataset() —— 在某个观察点上算 11 个特征 + 1 个标签

清洗口径对应 mysql/05_build_clean_table.sql 的 6 步漏斗：
    1. 剔取消订单（Invoice 以 C 开头）
    2. 剔退货（Quantity <= 0）
    3. 剔非正价格（Price <= 0）
    4. 剔非商品行（StockCode 不符合 ^[0-9]{5}[A-Za-z]*$）
    5. 去完全重复行
    6. 剔「被取消的原始订单行」（按 客户+商品+数量+价格 配对）

【关键：第 6 步必须按观察点重做】
    第 6 步用的是取消记录。如果拿全期取消记录去删历史订单，
    就可能用「4 月的取消」删掉「2 月的购买」——站在 2 月底做预测时，
    这个取消还没发生，模型不该知道。

    所以：load_data() 只做到第 5 步，返回原始销售明细 + 取消明细；
    build_dataset() 在观察点 T 上，只用 day <= T 的取消记录重建快照。
    标签先重建截至标签结束日的完整快照，再提取窗口内购买。
"""

import numpy as np
import pandas as pd

import config

FEATURE_COLUMNS = [
    "R", "F", "M", "AOV", "interval", "tenure",
    "products", "cancels", "is_uk", "recent_90", "seasonal",
]

RAW_COLUMNS = [
    "Invoice", "StockCode", "Description", "Quantity",
    "InvoiceDate", "Price", "Customer ID", "Country",
]
STOCKCODE_PATTERN = r"^[0-9]{5}[A-Za-z]*$"
CANCEL_KEY_COLUMNS = ["StockCode", "Quantity", "Price", "Customer_ID"]


def load_data():
    """读一次 CSV，返回（销售明细, 取消明细）。

    销售明细已执行漏斗 1-5 步（1,003,213 行）。
    第 6 步留给 build_dataset()，因为它的结果依赖观察点。
    """
    raw = pd.read_csv(config.RAW_CSV, encoding="utf-8-sig", dtype=str)
    raw.columns = [c.strip() for c in raw.columns]

    invoice = raw["Invoice"].str.strip()
    qty = pd.to_numeric(raw["Quantity"], errors="coerce")
    # MySQL 先 CAST(... AS DECIMAL(10,2)) 再比较，0.001 会被四舍五入成 0.00 剔除。
    # 这里先 round(2)，保证漏斗第 3 步的行数与 SQL 逐行一致。
    price = pd.to_numeric(raw["Price"], errors="coerce").round(2)

    # 漏斗 1-4：四个条件同时成立才保留
    # 注意 StockCode 用【原值】匹配（不 strip）：SQL 的 REGEXP 也是匹配原值，
    # 唯一一条 '47503J ' 带尾随空格的行在 MySQL 里会被拒绝，这里必须同样处理，
    # 否则清洗结果会多 1 行（£16.13），与看板口径对不上。
    valid = (
        invoice.notna()
        & ~invoice.str.startswith("C")
        & qty.gt(0)
        & price.gt(0)
        & raw["StockCode"].fillna("").str.fullmatch(STOCKCODE_PATTERN)
    ).fillna(False)

    # 漏斗 5：按文件里的原始值去重（对应 SQL 的 SELECT DISTINCT）
    kept = raw.loc[valid, RAW_COLUMNS].drop_duplicates()

    sales = pd.DataFrame({
        "Invoice": kept["Invoice"].str.strip(),
        "StockCode": kept["StockCode"].str.strip(),
        # Description 的 TRIM 放在去重之后，与 SQL 一致
        "Description": kept["Description"].str.strip(),
        "Quantity": pd.to_numeric(kept["Quantity"]).astype("int64"),
        "InvoiceDate": pd.to_datetime(kept["InvoiceDate"]),
        "Price": pd.to_numeric(kept["Price"]).round(2),
        "Customer_ID": pd.to_numeric(kept["Customer ID"], errors="coerce").astype("Int64"),
        "Country": kept["Country"].str.strip(),
    })
    sales["day"] = sales["InvoiceDate"].dt.normalize()
    sales["Revenue"] = sales["Quantity"] * sales["Price"]

    # 取消明细：C 开头且数量为负。一行 = 一个商品行，
    # 统计次数时要用 Invoice 去重（一张取消发票可能含 20 个商品行）。
    is_cancel = (
        invoice.str.startswith("C", na=False).fillna(False) & qty.lt(0).fillna(False)
    )
    cancel_date = pd.to_datetime(raw.loc[is_cancel, "InvoiceDate"])
    cancels = pd.DataFrame({
        "Invoice": raw.loc[is_cancel, "Invoice"].str.strip(),
        "StockCode": raw.loc[is_cancel, "StockCode"].str.strip(),
        "Quantity": (-qty[is_cancel]).astype("int64"),
        "Price": price[is_cancel],
        "Customer_ID": pd.to_numeric(raw.loc[is_cancel, "Customer ID"],
                                     errors="coerce").astype("Int64"),
        "InvoiceDate": cancel_date,
        "day": cancel_date.dt.normalize(),
    }).dropna(subset=["Customer_ID"])

    return sales, cancels


def remove_cancelled_originals(sales, cancels):
    """按 客户+商品+数量+价格 四要素配对，删掉被取消的原始订单行。

    比 SQL 版多两条约束（ML 模块单独采用，不改 SQL/看板的历史口径）：
      1. **购买时间 <= 取消时间**（保留时分秒）。取消不可能发生在购买之前；
         SQL 版只按数量截取最早几笔，会把「取消日期更早」的订单误删。
      2. 每笔销售、每条取消各用一次，贪心匹配：
         按取消时间从早到晚，配给第一笔「时间不晚于它」且尚未使用的销售。

    局限仍然存在：没有「原始订单 ↔ 取消单」的外键，四要素相同不代表同一笔交易。
    所以这是数量约束下的近似匹配，不是逐笔精确还原。
    """
    if cancels.empty:
        return sales, 0

    pos = sales[sales["Customer_ID"].notna()]
    if pos.empty:
        return sales, 0

    # 把销售和取消放在一起因子化，保证两边的 key 编码一致
    all_keys = pd.concat([pos[CANCEL_KEY_COLUMNS], cancels[CANCEL_KEY_COLUMNS]],
                         ignore_index=True)
    codes, _ = pd.factorize(pd.MultiIndex.from_frame(all_keys))
    pos_codes, can_codes = codes[:len(pos)], codes[len(pos):]

    pos = (pos.assign(_code=pos_codes)
              .sort_values(["_code", "InvoiceDate", "Invoice"], kind="stable"))
    pos = pos.assign(_order=pos.groupby("_code").cumcount())   # 组内按日期排名
    can = (cancels.assign(_code=can_codes)
                  .sort_values(["_code", "InvoiceDate", "Invoice"], kind="stable"))

    n_keys = int(codes.max()) + 1 if len(codes) else 0
    pos_sizes = (pos.groupby("_code").size()
                    .reindex(range(n_keys), fill_value=0).to_numpy())
    pos_starts = np.concatenate([[0], np.cumsum(pos_sizes)])
    pos_times = pos["InvoiceDate"].to_numpy()

    can_times = can["InvoiceDate"].to_numpy()
    can_codes_arr = can["_code"].to_numpy()
    can_starts = np.concatenate(
        [[0], np.cumsum(np.bincount(can_codes_arr, minlength=n_keys))])

    # 每个 key 内做两指针贪心匹配，得到「被删的销售是组内最早的 k 笔」
    matched = {}
    for code in np.unique(can_codes_arr):
        p = pos_times[pos_starts[code]:pos_starts[code + 1]]
        c = can_times[can_starts[code]:can_starts[code + 1]]
        used = 0
        for cancel_date in c:
            if used < len(p) and p[used] <= cancel_date:
                used += 1
        if used:
            matched[code] = used

    if not matched:
        return sales, 0

    drop_mask = pos["_order"] < pos["_code"].map(matched).fillna(0)
    drop_idx = pos.loc[drop_mask].index
    return sales.drop(index=drop_idx), len(drop_idx)


def build_invoice_table(rows):
    """把明细聚到发票粒度：同一个客户同一张发票 = 一行。"""
    return (rows.groupby(["Customer_ID", "Invoice"], as_index=False)
                 .agg(day=("day", "min"),
                      last_ts=("InvoiceDate", "max"),
                      amount=("Revenue", "sum")))


def build_dataset(sales, cancels, observation_date):
    """在观察点 T 上，为每个有购买记录的客户算 11 个特征 + 1 个标签。

    特征只用 day <= T 的销售与取消记录；
    标签先用截至 T+90 日末的完整历史配对，再取 (T, T+90] 内购买。
    """
    T = pd.Timestamp(observation_date)
    label_end = T + pd.Timedelta(days=config.LABEL_DAYS)

    # 时点快照：只用当时已知的信息
    snapshot, _ = remove_cancelled_originals(
        sales[sales["day"] <= T],
        cancels[cancels["day"] <= T],
    )

    # 固定样本为快照中仍有有效购买的实名客户。空表不能在后续赋值时
    # 被取消记录或未来购买的 Series 扩展出新客户。
    if not snapshot["Customer_ID"].notna().any():
        return pd.DataFrame(columns=["Customer_ID", *FEATURE_COLUMNS, "y"])

    # 标签：先构建「标签结束日」的完整快照，再取窗口内的购买。
    # 只把窗口内的购买与取消放在一起配对会出错：窗口内的取消行在窗口里
    # 找不到对应的原始订单时，会误删窗口内后来发生的新购。
    # 例：2/1 购买 → 3/1 取消这笔 → 3/2 再次购买，窗口内单独配对会把 3/2 删掉。
    through_label_end, _ = remove_cancelled_originals(
        sales[sales["day"] <= label_end],
        cancels[cancels["day"] <= label_end],
    )
    future = through_label_end[through_label_end["day"] > T]

    invoices = build_invoice_table(snapshot)
    by_customer = invoices.groupby("Customer_ID")
    df = pd.DataFrame({
        "F": by_customer.size(),                     # 2. 历史发票数
        "M": by_customer["amount"].sum(),            # 3. 历史消费总额
        "last_day": by_customer["day"].max(),
        "first_day": by_customer["day"].min(),
    })
    df["R"] = (T - df["last_day"]).dt.days           # 1. 最近一次购买距今天数
    df["tenure"] = (T - df["first_day"]).dt.days     # 6. 账龄
    df["AOV"] = df["M"] / df["F"]                    # 4. 平均每张发票金额

    # 7. 购买商品种数（去重 StockCode）
    df["products"] = snapshot.groupby("Customer_ID")["StockCode"].nunique()

    # 5. 平均购买间隔：相邻【购买日】间隔的均值。
    #    只买过一次的人没有间隔可算 → 留空（NaN），
    #    建模时用训练集中位数填充，填充值只从训练集来。
    days = (invoices[["Customer_ID", "day"]].drop_duplicates()
            .sort_values(["Customer_ID", "day"]))
    gaps = days.groupby("Customer_ID")["day"].diff().dt.days
    df["interval"] = gaps.groupby(days["Customer_ID"]).mean()

    # 8. 取消订单次数：按发票号去重，一张取消发票算 1 次
    known_cancels = cancels[cancels["day"] <= T]
    df["cancels"] = (known_cancels.groupby("Customer_ID")["Invoice"].nunique()
                     .reindex(df.index))

    # 9. 国家：取观察点前最后一单，英国 = 1，海外 = 0
    last_country = (snapshot.sort_values("InvoiceDate")
                    .groupby("Customer_ID")["Country"].last())
    df["is_uk"] = (last_country == "United Kingdom").astype("int64")

    # 10. 近 90 天购买次数
    recent = invoices[invoices["day"] > T - pd.Timedelta(days=config.RECENT_DAYS)]
    df["recent_90"] = recent.groupby("Customer_ID").size()

    # 11. 上年同期是否购买（季节性）：观察点前 365±45 天内有购买 → 1
    lo = T - pd.Timedelta(days=config.SEASON_CENTER_DAYS + config.SEASON_HALF_WIDTH)
    hi = T - pd.Timedelta(days=config.SEASON_CENTER_DAYS - config.SEASON_HALF_WIDTH)
    seasonal = invoices[(invoices["day"] >= lo) & (invoices["day"] <= hi)]
    df["seasonal"] = (seasonal.groupby("Customer_ID").size() > 0).astype("int64")

    # 标签：观察点之后 LABEL_DAYS 天内有没有产生未被取消的新发票
    df["y"] = (future.groupby("Customer_ID").size() > 0).astype("int64")

    # 计数类特征没有记录就是 0（没取消过、近 90 天没买、上年同期没买）
    for col in ["cancels", "recent_90", "seasonal", "y"]:
        df[col] = df[col].fillna(0).astype("int64")

    df = df.reset_index()
    return df[["Customer_ID", *FEATURE_COLUMNS, "y"]]


if __name__ == "__main__":
    sales, cancels = load_data()
    print(f"\n[对账] 漏斗 1-5 步后 {len(sales):,} 行（SQL 期望 1,003,213）")
    full, n_dropped = remove_cancelled_originals(sales, cancels)
    print(f"[对账] 第 6 步剔除 {n_dropped:,} 行"
          f"（SQL 口径 6,665；ML 增加时间戳先后约束，差 {6665 - n_dropped:,} 行）")
    print(f"[对账] ML 口径剩余 {len(full):,} 行（SQL 口径 996,548）")
    print(f"[对账] 总营收 {full['Revenue'].sum():,.2f}（SQL 口径 19,082,339.73）")
    print(f"[对账] 实名客户数 {full['Customer_ID'].nunique():,}（SQL 口径 5,835）")

    print("\n观察点        样本数   正例率   间隔缺失   曾被未来取消误删")
    for name, date in config.OBSERVATION_POINTS.items():
        T = pd.Timestamp(date)
        n_asof = len(remove_cancelled_originals(
            sales[sales["day"] <= T], cancels[cancels["day"] <= T])[0])
        n_all = len(remove_cancelled_originals(
            sales[sales["day"] <= T], cancels)[0])   # 旧做法：用全期取消
        ds = build_dataset(sales, cancels, date)
        print(f"{name} {date}  {len(ds):>6,}  {ds['y'].mean():>6.1%}  "
              f"{ds['interval'].isna().sum():>6,}  {n_asof - n_all:>6,}")
