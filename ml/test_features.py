"""特征构造的回归测试。

锁住三个容易改错的点：
    1. 取消日期早于购买日期时，不能配对
    2. 标签配对要看截至标签结束日的完整历史，不能只看标签窗口
    3. 取消次数按发票号去重，不按商品行

运行：
    python ml/test_features.py
"""

import pandas as pd

import features


def make_sales(rows):
    """rows: (Invoice, StockCode, Quantity, Price, Customer_ID, day)"""
    df = pd.DataFrame(rows, columns=[
        "Invoice", "StockCode", "Quantity", "Price", "Customer_ID", "day"])
    df["Quantity"] = df["Quantity"].astype("int64")
    df["Price"] = df["Price"].astype(float)
    df["Customer_ID"] = df["Customer_ID"].astype("Int64")
    df["InvoiceDate"] = pd.to_datetime(df["day"], format="ISO8601")
    df["day"] = df["InvoiceDate"].dt.normalize()
    df["Revenue"] = df["Quantity"] * df["Price"]
    df["Description"] = ""
    df["Country"] = "United Kingdom"
    return df


def test_cancel_before_purchase_not_matched():
    sales = make_sales([("A1", "X", 1, 5.0, 2, "2011-03-05")])
    cancels = make_sales([("C1", "X", 1, 5.0, 2, "2011-03-01")])
    kept, n = features.remove_cancelled_originals(sales, cancels)
    assert n == 0 and kept["Invoice"].tolist() == ["A1"], "取消早于购买，不应配对"


def test_cancel_removes_matching_purchase():
    sales = make_sales([
        ("A1", "X", 1, 10.0, 1, "2011-02-01"),
        ("A2", "X", 1, 10.0, 1, "2011-03-02"),
    ])
    cancels = make_sales([("C1", "X", 1, 10.0, 1, "2011-03-01")])
    kept, n = features.remove_cancelled_originals(sales, cancels)
    assert n == 1 and kept["Invoice"].tolist() == ["A2"], "应删掉 2/1 那笔，保留 3/2"


def test_label_uses_full_history_until_label_end():
    """2/1 买 → 3/1 取消 → 3/2 再买，标签应为 1（有新购买）。"""
    sales = make_sales([
        ("A1", "X", 1, 10.0, 1, "2011-02-01"),
        ("A2", "X", 1, 10.0, 1, "2011-03-02"),
    ])
    cancels = make_sales([("C1", "X", 1, 10.0, 1, "2011-03-01")])

    ds = features.build_dataset(sales, cancels, "2011-02-28")
    row = ds.iloc[0]
    assert row["y"] == 1, f"标签应为 1，实际 {row['y']}"
    assert row["F"] == 1, f"观察点前应有 1 张发票（2/1 那笔当时还没取消），实际 {row['F']}"


def test_cancels_counted_by_invoice():
    """一张取消发票有 2 个商品行，取消次数应为 1。"""
    sales = make_sales([
        ("A1", "X", 1, 10.0, 1, "2011-01-10"),
        ("A2", "Y", 2, 5.0, 1, "2011-01-10"),
        ("A3", "Z", 1, 3.0, 1, "2011-01-11"),
    ])
    cancels = make_sales([
        ("C1", "X", 1, 10.0, 1, "2011-01-20"),
        ("C1", "Y", 2, 5.0, 1, "2011-01-20"),
    ])
    ds = features.build_dataset(sales, cancels, "2011-02-28")
    assert ds.iloc[0]["cancels"] == 1, f"取消次数应为 1，实际 {ds.iloc[0]['cancels']}"


def test_features_include_observation_day():
    """观察点当天的购买要计入 F、商品种数和国家，与 SQL 按日口径一致。"""
    sales = make_sales([
        ("A1", "X", 1, 10.0, 1, "2011-02-27"),
        ("A2", "Y", 1, 3.0, 1, "2011-02-28 18:00:00"),
    ])
    empty = make_sales([])
    ds = features.build_dataset(sales, empty, "2011-02-28")
    row = ds.iloc[0]
    assert row["F"] == 2, f"当天购买应计入，F 应为 2，实际 {row['F']}"
    assert row["products"] == 2, f"当天购买应计入商品种数，实际 {row['products']}"


def test_same_day_cancel_before_purchase_not_matched():
    sales = make_sales([("A1", "X", 1, 10., 1, "2011-03-01 15:00:00")])
    cancels = make_sales([("C1", "X", 1, 10., 1, "2011-03-01 09:00:00")])
    kept, n = features.remove_cancelled_originals(sales, cancels)
    assert n == 0 and kept["Invoice"].tolist() == ["A1"]


def test_same_day_matching_uses_time_not_invoice_order():
    sales = make_sales([
        ("A1", "X", 1, 10., 1, "2011-03-01 15:00:00"),
        ("A2", "X", 1, 10., 1, "2011-03-01 08:00:00"),
    ])
    cancels = make_sales([("C1", "X", 1, 10., 1, "2011-03-01 09:00:00")])
    kept, n = features.remove_cancelled_originals(sales, cancels)
    assert n == 1 and kept["Invoice"].tolist() == ["A1"]


def test_all_purchases_cancelled_returns_empty_dataset():
    sales = make_sales([("A1", "X", 1, 10., 1, "2011-01-10")])
    cancels = make_sales([("C1", "X", 1, 10., 1, "2011-01-20")])
    ds = features.build_dataset(sales, cancels, "2011-02-28")
    assert ds.empty
    assert ds.columns.tolist() == ["Customer_ID", *features.FEATURE_COLUMNS, "y"]


def test_no_history_does_not_admit_future_or_cancel_only_customers():
    sales = make_sales([("A1", "X", 1, 10., 1, "2011-03-10")])
    cancels = make_sales([("C1", "Y", 1, 10., 2, "2011-01-20")])
    assert features.build_dataset(sales, cancels, "2011-02-28").empty


def test_each_sale_and_cancel_used_once():
    sales = make_sales([
        ("A1", "X", 1, 10., 1, "2011-01-10"),
        ("A2", "X", 1, 10., 1, "2011-01-11"),
    ])
    cancels = make_sales([("C1", "X", 1, 10., 1, "2011-01-20")])
    kept, n = features.remove_cancelled_originals(sales, cancels)
    assert n == 1 and kept["Invoice"].tolist() == ["A2"]


def test_future_cancel_changes_label_but_not_features():
    sales = make_sales([
        ("A1", "X", 1, 10., 1, "2011-01-10"),
        ("A2", "Y", 1, 20., 1, "2011-03-10"),
    ])
    cancels = make_sales([("C1", "Y", 1, 20., 1, "2011-03-20")])
    before = features.build_dataset(sales, make_sales([]), "2011-02-28")
    after = features.build_dataset(sales, cancels, "2011-02-28")
    pd.testing.assert_frame_equal(before.drop(columns="y"), after.drop(columns="y"))
    assert before.iloc[0]["y"] == 1 and after.iloc[0]["y"] == 0


if __name__ == "__main__":
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS  {test.__name__}")
    print(f"\n{len(tests)} 个测试全部通过")
