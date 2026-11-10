"""python -m agent.run --question '2011年前11个月销售额同比怎么样？'"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

from .runtime import Agent


def main():
    parser = argparse.ArgumentParser(description="电商分析 Agent（真实模型工具调用）")
    parser.add_argument("--question", "-q", required=True)
    parser.add_argument("--json", action="store_true", help="打印完整工具调用记录")
    args = parser.parse_args()
    try:
        result = Agent().ask(args.question)
        path = Path(__file__).resolve().parent / "traces"
        path.mkdir(exist_ok=True)
        trace_path = path / (datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".json")
        trace_path.write_text(json.dumps({"question": args.question, **result}, ensure_ascii=False, indent=2), encoding="utf-8")
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(result["answer"])
            print("\n来源：" + ", ".join(result["sources"]))
            print(f"状态：{result['status']}；耗时：{result['elapsed_seconds']}秒；工具调用：{len(result['trace'])}次")
            print(f"记录：{trace_path}")
        return 1 if result["status"] == "error" else 0
    except (RuntimeError, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
