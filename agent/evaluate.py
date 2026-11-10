"""固定题集上的真实模型评测。通过条件包括状态、工具选择、参数与答案数字。

不会将工具单测或模拟模型当作真实模型准确率；失败原样记录，不自动重试挑好成绩。
"""

import argparse
import json
import re
import statistics
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from .provider import DeepSeekClient
from .runtime import Agent

DIRECTORY = Path(__file__).resolve().parent


def check(case, result):
    failures = []
    if result["status"] not in case["status"]:
        failures.append("status")
    successes = [step for step in result["trace"] if step["result"].get("ok")]
    names = {step["tool"] for step in successes}
    if not set(case.get("tools", [])) <= names:
        failures.append("tool_selection")
    if names & set(case.get("forbidden_success_tools", [])):
        failures.append("ignored_filter")
    if "args" in case and not any(all(s["arguments"].get(k) == v for k, v in case["args"].items()) for s in successes if s["tool"] == "customer_list"):
        failures.append("arguments")
    text = result["answer"].replace(",", "").replace("，", "").replace("−", "-")
    numbers = [float(n) for n in re.findall(r"(?<![\d.])-?\d+(?:\.\d+)?", text)]
    # 支持明确标注的万/百万金额，防止中文格式把正确回答误判为失败。
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)\s*(百万|万)", text):
        numbers.append(float(value) * (1000000 if unit == "百万" else 10000))
    for expected in case.get("numbers", []):
        tolerance = .00051 if abs(expected) < 1 else (.011 if abs(expected) < 100 else .011)
        if not any(abs(actual - expected) <= tolerance for actual in numbers):
            failures.append(f"answer_number:{expected}")
    if "contains_any" in case and not any(s in text for s in case["contains_any"]):
        failures.append("answer_boundary")
    for step in successes:
        if step["tool"] == "customer_list":
            ids = [str(row["Customer_ID"]) for row in step["result"]["data"]["customers"]]
            positions = [text.find(cid) for cid in ids]
            if any(pos < 0 for pos in positions) or positions != sorted(positions):
                failures.append("customer_order")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0, help="0为全部固定题；少量试跑不替代全量成绩")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--cases", default=str(DIRECTORY / "eval_cases.json"))
    parser.add_argument("--output", default=str(DIRECTORY / "outputs" / "eval_report.json"))
    args = parser.parse_args()
    cases = json.loads(Path(args.cases).read_text(encoding="utf-8"))
    if args.limit:
        cases = cases[:args.limit]
    client = DeepSeekClient()

    def evaluate(case):
        try:
            result = Agent(client=client).ask(case["question"], case.get("history"))
            failures = check(case, result)
        except (RuntimeError, ValueError, OSError) as exc:
            result = {"status": "error", "answer": str(exc), "trace": [], "sources": [], "elapsed_seconds": 0}
            failures = ["execution_error"]
        return {"id": case["id"], "question": case["question"], "passed": not failures,
                "failures": failures, "result": result}

    with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 4))) as pool:
        results = list(pool.map(evaluate, cases))
    passed = sum(row["passed"] for row in results)
    latencies = sorted(row["result"]["elapsed_seconds"] for row in results)
    report = {"evaluated_at_utc": datetime.now(timezone.utc).isoformat(), "model": client.model,
              "suite": Path(args.cases).stem, "count": len(results), "passed": passed,
              "pass_rate": passed / len(results), "median_seconds": statistics.median(latencies),
              "p95_seconds": latencies[min(len(latencies) - 1, int(len(latencies) * .95))],
              "grading": "状态/成功工具/部分参数/指定数字与边界关键词；非完整语义或因果正确性证明，未使用LLM裁判",
              "results": results}
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "results"}, ensure_ascii=False, indent=2))
    for row in results:
        if not row["passed"]:
            print(row["id"], row["failures"], row["result"]["answer"])


if __name__ == "__main__":
    main()
