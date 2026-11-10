"""一条命令跑完：清洗 → 特征 → 训练 → 评估 → 输出。

用法：
    python ml/run.py
"""

import evaluate
import config
import model


def main():
    config.OUT_DIR.mkdir(parents=True, exist_ok=True)

    outputs = model.run()
    evaluate.report(outputs, config.OUT_DIR)

    metrics = outputs["metrics"]
    print("\n" + "=" * 56)
    print("三窗口平均 AUC（逻辑回归）:", round(
        metrics.query("model == '逻辑回归'")["auc"].mean(), 3))
    print("输出目录:", config.OUT_DIR)


if __name__ == "__main__":
    main()
