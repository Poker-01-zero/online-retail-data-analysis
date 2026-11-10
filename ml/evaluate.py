"""评估输出：分档提升度、提升度曲线、召回名单、指标汇总。

提升度的算法：
    整体正例率 = 测试集里复购客户的比例（比如 33%）
    前 10% 名单命中率 = 名单里真正复购的人占多少（比如 82%）
    提升度 = 82% / 33% ≈ 2.5
含义：高分名单的自然复购率是全体的约 2.5 倍。
这衡量排序能力，不能解释为打电话带来的增量复购。
"""

import matplotlib

matplotlib.use("Agg")   # 不弹窗，直接存文件

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

import config

CUTS = [0.01, 0.05, 0.10, 0.20, 0.30, 0.50]

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False


def lift_table(y_true, score, cuts=CUTS):
    """按分数从高到低排，取前 1%/5%/10%… 算命中率和提升度。"""
    y = np.asarray(y_true)
    y_sorted = y[np.argsort(-np.asarray(score))]
    base = y.mean()
    total_positive = y.sum()

    rows = []
    for cut in cuts:
        n = max(1, int(round(len(y_sorted) * cut)))
        hit = int(y_sorted[:n].sum())
        rows.append({
            "名单比例": cut,
            "人数": n,
            "命中人数": hit,
            "命中率": round(hit / n, 4),
            "提升度": round((hit / n) / base, 3),
            "覆盖复购客户": round(hit / total_positive, 4),
        })
    return pd.DataFrame(rows)


def cumulative_lift(y_true, score, points=100):
    """整条提升度曲线：横轴名单比例，纵轴提升度。"""
    y = np.asarray(y_true)
    y_sorted = y[np.argsort(-np.asarray(score))]
    base = y.mean()
    fracs = np.linspace(1 / points, 1.0, points)
    lifts = [y_sorted[:max(1, int(round(len(y) * f)))].mean() / base for f in fracs]
    return fracs, np.array(lifts)


def build_churn_list(test, prob):
    """召回优先级名单。

    优先级分 = 历史价值 × (1 − 复购概率)
    这是历史消费金额与未来 90 天未复购风险的启发式组合，
    用于生成候选实验池；未验证其触达收益，也不代表永久流失概率。
    """
    out = pd.DataFrame({
        "Customer_ID": test["Customer_ID"].to_numpy(),
        "复购概率": np.round(prob, 4),
        "历史价值": np.round(test["M"].to_numpy(), 2),
        "R_距今购买天数": test["R"].to_numpy(),
        "F_历史发票数": test["F"].to_numpy(),
    })
    out["优先级分"] = np.round(out["历史价值"] * (1 - out["复购概率"]), 2)
    out = out.sort_values("优先级分", ascending=False, ignore_index=True)
    out.insert(0, "优先级", np.arange(1, len(out) + 1))
    return out


def plot_lift_curve(outputs, path):
    fig, ax = plt.subplots(figsize=(7.5, 4.8))
    for name in config.EVAL_WINDOWS:
        test = outputs[name]["test"]
        fracs, lifts = cumulative_lift(test["y"], outputs[name]["scores"]["lr"])
        auc = outputs["metrics"].query(
            "window == @name and model == '逻辑回归'")["auc"].iloc[0]
        ax.plot(fracs * 100, lifts, label=f"{name}（AUC {auc:.3f}）")

    ax.axhline(1.0, color="#888888", linestyle="--", linewidth=1)
    ax.text(55, 1.08, "随机触达 = 1.0", color="#888888", fontsize=9)
    ax.set_xlabel("召回的客户比例（%，按模型分数从高到低）")
    ax.set_ylabel("提升度（名单命中率 ÷ 整体复购率）")
    ax.set_title("复购预测 · 提升度曲线（逻辑回归）")
    ax.set_xlim(0, 100)
    ax.grid(alpha=0.25)
    ax.legend(frameon=False)
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)


def report(outputs, out_dir):
    """把三块结果写成文件，并在终端打印分档表。"""
    out_dir.mkdir(parents=True, exist_ok=True)

    metrics = outputs["metrics"]
    metrics.to_csv(out_dir / "metrics.csv", index=False, encoding="utf-8-sig")

    lift_frames = []
    for name in config.EVAL_WINDOWS:
        test = outputs[name]["test"]
        table = lift_table(test["y"], outputs[name]["scores"]["lr"])
        table.insert(0, "window", name)
        lift_frames.append(table)
        print(f"\n[{name}] 逻辑回归分档提升度")
        print(table.to_string(index=False))

    lift_all = pd.concat(lift_frames, ignore_index=True)
    lift_all.to_csv(out_dir / "lift_table.csv", index=False, encoding="utf-8-sig")

    plot_lift_curve(outputs, out_dir / "lift_curve.png")

    last = config.EVAL_WINDOWS[-1]
    churn = build_churn_list(outputs[last]["test"], outputs[last]["scores"]["lr"])
    churn.to_csv(out_dir / "churn_list.csv", index=False, encoding="utf-8-sig")
    print(f"\n召回名单（{last}）：{len(churn):,} 人，前 5 行")
    print(churn.head().to_string(index=False))
    print(f"名单合计历史价值 GBP {churn['历史价值'].sum():,.0f}")

    return {"metrics": metrics, "lift": lift_all, "churn": churn}
