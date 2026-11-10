"""重算时间戳配对对账、未来取消影响和 W3 候选池统计。

先运行 python ml/run.py，再运行 python ml/audit.py。
"""

import json

import pandas as pd

import config
from features import build_dataset, load_data, remove_cancelled_originals


def run():
    sales, cancels = load_data()
    full, removed = remove_cancelled_originals(sales, cancels)
    result = {
        "full": {
            "removed": removed,
            "remaining": len(full),
            "revenue": round(float(full.Revenue.sum()), 2),
            "customers": int(full.Customer_ID.nunique()),
            "sql_row_difference": 6665 - removed,
            "sql_revenue_difference": round(float(full.Revenue.sum()) - 19082339.73, 2),
        },
        "windows": {},
    }
    for name, date in config.OBSERVATION_POINTS.items():
        t = pd.Timestamp(date)
        history = sales[sales.day <= t]
        snapshot, _ = remove_cancelled_originals(history, cancels[cancels.day <= t])
        all_cancels, _ = remove_cancelled_originals(history, cancels)
        affected = snapshot.loc[~snapshot.index.isin(all_cancels.index)]
        ds = build_dataset(sales, cancels, date)
        assert not ds.Customer_ID.duplicated().any()
        assert ds.drop(columns="interval").notna().all().all()
        result["windows"][name] = {
            "n": len(ds), "pos_rate": float(ds.y.mean()),
            "future_cancel_rows": len(affected),
            "affected_customers": int(affected.Customer_ID.nunique()),
            "historical_rows": len(history),
            "pct_history": len(affected) / len(history) * 100,
        }
        if name == config.EVAL_WINDOWS[-1]:
            candidates = pd.read_csv(config.OUT_DIR / "churn_list.csv",
                                     encoding="utf-8-sig").set_index("Customer_ID")
            if candidates.index.has_duplicates or set(candidates.index) != set(ds.Customer_ID):
                raise ValueError("名单客户与当前快照不一致，请先重跑 ml/run.py")
            candidates["y"] = ds.set_index("Customer_ID").y
            end = t + pd.Timedelta(days=config.LABEL_DAYS)
            end_snapshot, _ = remove_cancelled_originals(
                sales[sales.day <= end], cancels[cancels.day <= end])
            revenues = (end_snapshot[end_snapshot.day > t]
                        .groupby("Customer_ID").Revenue.sum())
            candidates["rev"] = revenues.reindex(candidates.index).fillna(0)
            result["segments"] = {}
            for fraction in [0.2, 0.3, 0.5]:
                segment = candidates.head(round(len(candidates) * fraction))
                result["segments"][str(fraction)] = {
                    "n": len(segment), "rate": float(segment.y.mean()),
                    "historical_value": float(segment["历史价值"].mean()),
                    "revenue": float(segment.rev.mean()),
                    "buyer_revenue": float(segment.loc[segment.y == 1, "rev"].mean()),
                }
    config.OUT_DIR.mkdir(parents=True, exist_ok=True)
    (config.OUT_DIR / "audit_summary.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result


if __name__ == "__main__":
    run()
