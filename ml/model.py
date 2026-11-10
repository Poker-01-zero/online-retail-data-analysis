"""训练与评估：逻辑回归 + 随机森林，三窗口滚动验证。

滚动方案（训练集永远只含测试窗口之前的数据）：

    W1 的模型 ← 用 T0 训练，在 W1 上评估
    W2 的模型 ← 用 T0+W1 训练，在 W2 上评估
    W3 的模型 ← 用 T0+W1+W2 训练，在 W3 上评估
"""

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

import config
from features import FEATURE_COLUMNS, build_dataset, load_data

MODEL_NAMES = {"lr": "逻辑回归", "rf": "随机森林"}


def make_logistic():
    """中位数填充 → 标准化 → 逻辑回归。

    填充和标准化都放在 Pipeline 里，fit 时只用训练集，
    测试集走 transform，填充值和中位数不会从测试集泄露过来。
    """
    return Pipeline([
        ("impute", SimpleImputer(strategy="median")),
        ("scale", StandardScaler()),
        ("model", LogisticRegression(max_iter=1000)),
    ])


def make_forest():
    return Pipeline([
        ("impute", SimpleImputer(strategy="median")),
        ("model", RandomForestClassifier(
            n_estimators=300,
            min_samples_leaf=20,    # 叶子至少 20 人，防止记住个别客户
            max_features="sqrt",
            random_state=config.RANDOM_STATE,
            n_jobs=-1,
        )),
    ])


def load_windows():
    """读数据，在每个观察点上构造特征表。"""
    clean, cancels = load_data()
    return {name: build_dataset(clean, cancels, date)
            for name, date in config.OBSERVATION_POINTS.items()}


def rolling_splits(windows):
    """按时间滚动切分：第 i 个窗口做测试集时，训练集是前面所有窗口。"""
    names = list(windows)
    for i, name in enumerate(names[1:], start=1):
        train = pd.concat([windows[n] for n in names[:i]], ignore_index=True)
        yield name, train, windows[name]


def single_feature_auc(train, test, column):
    """单特征基线：只用这一个特征排序的 AUC。

    R 和 interval 越小越可能复购，方向取反。
    """
    imputer = SimpleImputer(strategy="median").fit(train[[column]])
    x = imputer.transform(test[[column]]).ravel()
    direction = -1 if column in ("R", "interval") else 1
    return roc_auc_score(test["y"], direction * x)


def train_and_score(train, test):
    """在训练集上拟合两个模型，返回它们在测试集上的复购概率。"""
    x_train, y_train = train[FEATURE_COLUMNS], train["y"]
    x_test = test[FEATURE_COLUMNS]

    logistic = make_logistic().fit(x_train, y_train)
    forest = make_forest().fit(x_train, y_train)

    return {
        "lr": logistic,
        "rf": forest,
        "scores": {
            "lr": logistic.predict_proba(x_test)[:, 1],
            "rf": forest.predict_proba(x_test)[:, 1],
        },
    }


def run():
    """跑完三个窗口，返回结果字典（供 evaluate.py / run.py 使用）。"""
    windows = load_windows()
    records = []
    outputs = {}

    for name, train, test in rolling_splits(windows):
        fitted = train_and_score(train, test)
        y_test = test["y"]
        outputs[name] = {"test": test, **fitted}

        for key, model_name in MODEL_NAMES.items():
            auc = roc_auc_score(y_test, fitted["scores"][key])
            records.append({
                "window": name,
                "model": model_name,
                "auc": round(auc, 4),
                "n_train": len(train),
                "n_test": len(test),
                "pos_rate": round(float(y_test.mean()), 4),
            })
            print(f"[{name}] {model_name}  AUC = {auc:.3f}"
                  f"   (训练 {len(train):,} / 测试 {len(test):,}，"
                  f"正例率 {y_test.mean():.1%})")

        print("      单特征基线：", end="")
        print("  ".join(
            f"{col}={single_feature_auc(train, test, col):.3f}"
            for col in ["R", "F", "M", "products"]
        ))

    outputs["metrics"] = pd.DataFrame(records)
    return outputs


if __name__ == "__main__":
    result = run()
    print("\n" + result["metrics"].to_string(index=False))
