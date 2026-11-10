"""离线测试验证业务工具和调用循环；不把模拟模型计作真实模型评测。"""

import json
import sqlite3
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path

from .data import build_database, connect
from .runtime import Agent
from .tools import ToolBox


class AgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = Path(__file__).resolve().parent / "data"
        directory.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(dir=directory)
        cls.path = Path(cls.temp.name) / "retail.sqlite"
        build_database(cls.path)
        cls.tools = ToolBox(cls.path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_known_month(self):
        r = self.tools.call("monthly_metrics", {"start_month": "2010-01", "end_month": "2010-01"})
        self.assertEqual(r["data"]["totals"]["revenue_gbp"], 605680.25)
        self.assertTrue(r["sources"][0]["sha256"])

    def test_weighted_aov(self):
        r = self.tools.call("monthly_metrics", {"start_month": "2010-01", "end_month": "2010-02"})
        self.assertEqual(r["data"]["totals"]["aov_gbp"], round((605680.25 + 528123.03) / (1037 + 1175), 2))

    def test_yoy(self):
        r = self.tools.call("compare_years", {"year_a": 2010, "year_b": 2011, "start_month": 1, "end_month": 11})
        self.assertAlmostEqual(r["data"]["change_pct"]["revenue_gbp"], 2.56, places=2)

    def test_incomplete_month_requires_explicit_opt_in(self):
        args = {"start_month": "2011-12", "end_month": "2011-12"}
        self.assertEqual(self.tools.call("monthly_metrics", args)["error"]["code"], "incomplete_period")
        self.assertTrue(self.tools.call("monthly_metrics", {**args, "allow_incomplete": True})["warnings"])

    def test_outside_data_and_invalid_month(self):
        for start, code in [("2026-01", "out_of_range"), ("2011-13", "invalid_period")]:
            r = self.tools.call("monthly_metrics", {"start_month": start, "end_month": start})
            self.assertEqual(r["error"]["code"], code)

    def test_unsupported_country_is_not_silently_ignored(self):
        r = self.tools.call("monthly_metrics", {"start_month": "2011-01", "end_month": "2011-02", "country": "UK"})
        self.assertFalse(r["ok"])

    def test_list_sortings_and_limits(self):
        for sort in ["priority", "probability"]:
            r = self.tools.call("customer_list", {"sort_by": sort, "limit": 3, "observation_date": "2011-08-31"})
            self.assertEqual(len(r["data"]["customers"]), 3)
        priority = self.tools.call("customer_list", {"sort_by": "priority", "limit": 3, "observation_date": "2011-08-31"})
        self.assertEqual(priority["data"]["customers"][0]["Customer_ID"], "13902")
        self.assertFalse(self.tools.call("customer_list", {"sort_by": "priority", "limit": 5000, "observation_date": "2011-08-31"})["ok"])

    def test_today_snapshot_rejected(self):
        r = self.tools.call("customer_list", {"sort_by": "priority", "limit": 3, "observation_date": "2026-11-10"})
        self.assertEqual(r["error"]["code"], "unsupported_snapshot")

    def test_probability_ties_and_application_rendering(self):
        args = {"sort_by": "probability", "limit": 3, "observation_date": "2011-08-31"}
        result = self.tools.call("customer_list", args)
        rows = result["data"]["customers"]
        self.assertEqual([row["Customer_ID"] for row in rows], ["12748", "13089", "13694"])
        self.assertEqual([row["查询排名"] for row in rows], [1, 2, 3])
        answer = Agent.finish("answered", "历史概率名单。", [{"tool": "customer_list", "arguments": args, "result": result}], [], time.perf_counter())["answer"]
        self.assertLess(answer.index("12748"), answer.index("13089"))
        self.assertIn("不保证一定复购", answer)

    def test_sql_and_unknown_tool_rejected(self):
        self.assertFalse(self.tools.call("execute_sql", {"sql": "DROP TABLE candidates"})["ok"])
        self.assertFalse(self.tools.call("segment_summary", {"kind": "rfm; DROP TABLE monthly"})["ok"])
        with closing(connect(self.path)) as conn:
            with self.assertRaises(sqlite3.OperationalError):
                conn.execute("DELETE FROM monthly")

    def test_bool_is_not_integer(self):
        r = self.tools.call("customer_list", {"sort_by": "priority", "limit": True, "observation_date": "2011-08-31"})
        self.assertFalse(r["ok"])

    def test_model_evaluation(self):
        r = self.tools.call("model_report", {"window": "all"})
        self.assertAlmostEqual(r["data"]["lr_mean_auc"], .7961, places=4)

    def test_runtime_feedback_loop(self):
        class ScriptedClient:
            def complete(self, messages, tools):
                if messages[-1]["role"] != "tool":
                    return {"role": "assistant", "content": None, "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "model_report", "arguments": '{"window":"W3"}'}}]}, {}
                self_result = json.loads(messages[-1]["content"])
                assert self_result["ok"]
                return {"content": '{"status":"answered","answer":"W3逻辑回归AUC为0.7888。"}'}, {}
        result = Agent(self.tools, ScriptedClient()).ask("W3模型成绩")
        self.assertEqual(result["status"], "answered")
        self.assertEqual(len(result["trace"]), 1)
        self.assertIn("ml/outputs/metrics.csv", result["sources"])

    def test_unproven_answer_not_returned(self):
        class UnprovenClient:
            def complete(self, messages, tools):
                return {"content": '{"status":"answered","answer":"销售额999999"}'}, {}
        self.assertEqual(Agent(self.tools, UnprovenClient()).ask("销售额")["status"], "error")

    def test_model_cannot_guess_comparison_dates(self):
        class GuessingClient:
            def complete(self, messages, tools):
                if messages[-1]["role"] == "tool":
                    assert json.loads(messages[-1]["content"])["error"]["code"] == "needs_clarification"
                    return {"content": '{"status":"clarify","answer":"请提供同比年份和月份范围。"}'}, {}
                return {"content": None, "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "compare_years", "arguments": '{"year_a":2010,"year_b":2011,"start_month":1,"end_month":11}'}}]}, {}
        result = Agent(self.tools, GuessingClient()).ask("销售额同比怎么样？")
        self.assertEqual(result["status"], "clarify")
        self.assertFalse(result["trace"][0]["result"]["ok"])

    def test_year_filtered_segment_cannot_read_full_period(self):
        class FilterDroppingClient:
            def complete(self, messages, tools):
                if messages[-1]["role"] == "tool":
                    assert json.loads(messages[-1]["content"])["error"]["code"] == "unsupported_scope"
                    return {"content": '{"status":"clarify","answer":"分层只有全期数据，是否接受全期口径？"}'}, {}
                return {"content": None, "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "segment_summary", "arguments": '{"kind":"rfm"}'}}]}, {}
        result = Agent(self.tools, FilterDroppingClient()).ask("单独列2011年的RFM，不要用全期替代。")
        self.assertEqual(result["status"], "clarify")
        self.assertNotIn("data", result["trace"][0]["result"])


if __name__ == "__main__":
    unittest.main()
