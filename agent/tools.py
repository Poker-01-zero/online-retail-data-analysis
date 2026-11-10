"""白名单工具。所有 SQL 都由程序固定，模型只提供经过校验的业务参数。"""

import re
from contextlib import closing
from decimal import Decimal

from .data import DB_PATH, connect, verify_database


def schema(name, description, properties, required=()):
    return {"type": "function", "function": {"name": name, "description": description,
            "parameters": {"type": "object", "properties": properties,
                           "required": list(required), "additionalProperties": False}}}


def choice(values, description):
    return {"type": "string", "enum": values, "description": description}


TOOLS = [
    schema("monthly_metrics", "查询指定连续月份的营收、发票订单数和加权AOV，GBP。无国家/商品维度。默认拒绝包含不完整月2011-12的汇总。",
           {"start_month": {"type": "string", "description": "YYYY-MM"},
            "end_month": {"type": "string", "description": "YYYY-MM"},
            "allow_incomplete": {"type": "boolean", "description": "只有用户明确要求不完整月份的已记录值时才为true"}},
           ["start_month", "end_month"]),
    schema("compare_years", "比较两年相同月份范围的营收/订单数/加权AOV及同比，全部国家含匿名。用户说同比但未给完整年份或月份范围时先澄清。",
           {"year_a": {"type": "integer"}, "year_b": {"type": "integer"},
            "start_month": {"type": "integer", "minimum": 1, "maximum": 12},
            "end_month": {"type": "integer", "minimum": 1, "maximum": 12}},
           ["year_a", "year_b", "start_month", "end_month"]),
    schema("segment_summary", "读取全期汇总：rfm实名客户分层、abc商品销售贡献、pareto实名客户十分位；不支持按年/国家过滤。这些为SQL历史口径。",
           {"kind": choice(["rfm", "abc", "pareto"], "分层方法")}, ["kind"]),
    schema("customer_list", "查询2011-08-31历史观察点的离线客户名单：priority按历史消费金额乘90天未复购概率；probability按复购概率降序。不是今日名单，无国家维度。",
           {"sort_by": choice(["priority", "probability"], "必须区分两种排序"),
            "limit": {"type": "integer", "minimum": 1, "maximum": 50},
            "observation_date": {"type": "string", "description": "必须为2011-08-31"}},
           ["sort_by", "limit", "observation_date"]),
    schema("model_report", "读取三窗口的两个模型AUC与按复购概率排序的提升度；不代表候选池触达收益，也不能证明发券有效。",
           {"window": choice(["all", "W1", "W2", "W3"], "窗口")}, ["window"]),
    schema("metric_definition", "读取指标口径、SQL与ML清洗差异、因果边界、字段不足及能力范围。遇到利润、库存、国家分组、今日数据、写操作、不支持问题，用limitations。",
           {"topic": choice(["aov", "auc", "lift", "candidate", "cleaning", "causality", "limitations"], "口径主题")}, ["topic"]),
]

DEFINITIONS = {
    "aov": "AOV=选定期间营收总额/去重发票订单数，不是各月AOV的简单平均。月度表已按发票聚合，币种GBP。",
    "auc": "AUC衡量正负样本的分数排序能力；并列计半分。不等于预测准确率、概率校准或发券增量。",
    "lift": "Lift@10%=按复购概率降序的前10%客户实测复购率/同窗口整体复购率。这里的10%是概率名单，不是召回优先级名单。",
    "candidate": "候选优先级=历史消费金额M×(1−90天复购概率)，属启发式实验池；排序尚未验证触达收益，不代表永久流失。仅有2011-08-31历史名单。",
    "cleaning": "SQL历史口径剔除6665行，清洗后996548行、营收19082339.73 GBP、实名客户5835。ML额外约束完整购买时间戳不晚于取消时间戳，全期剔除6067行，余997146行、营收19092681.79 GBP、实名5839，差598行和10342.06 GBP。ML各观察点只用当时已知信息。缺少原订单关联字段，两者均为四要素近似配对；匹配敏感性分析尚未完成。",
    "causality": "无营销干预与对照数据，AUC和名单命中率不能证明发券有效。拟议实验：候选优先级前30% 1565人，783发券、782同样触达不发券；比较90天复购率与全组人均营收差值。实验尚未开展。两组均触达测的是券的增量，不是联系相对不联系的增量。",
    "limitations": "本助手仅支持2009-12至2011-12的已有离线月度汇总（2011-12仅到12月9日）、全期RFM/ABC/帕累托、三窗口ML评估和2011-08-31名单。无利润/进货成本/库存/营销干预/联系方式/实时数据；导出汇总无国家筛选。不能计算这些缺失指标、发送券、删除或更新数据，也不能执行任意SQL/代码。年份、同比区间或名单排序不清时先澄清。",
}


class ToolError(ValueError):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


class ToolBox:
    def __init__(self, path=DB_PATH):
        self.path = path
        self.manifest = verify_database(path)

    def rows(self, sql, params=()):
        with closing(connect(self.path)) as conn:
            return [dict(row) for row in conn.execute(sql, params)]

    def call(self, name, arguments):
        try:
            spec = next((t["function"] for t in TOOLS if t["function"]["name"] == name), None)
            if spec is None:
                raise ToolError("unknown_tool", "没有这个工具")
            self.validate(arguments, spec["parameters"])
            data, sources, scope, warnings = getattr(self, name)(**arguments)
            return {"ok": True, "data": data, "sources": [self.manifest[s] for s in sources],
                    "scope": scope, "warnings": warnings}
        except ToolError as exc:
            return {"ok": False, "error": {"code": exc.code, "message": str(exc)}}
        except (TypeError, ValueError, KeyError):
            return {"ok": False, "error": {"code": "invalid_arguments", "message": "参数类型、格式或范围不合法，请按工具定义修正。"}}

    @staticmethod
    def validate(args, spec):
        if not isinstance(args, dict) or set(args) - set(spec["properties"]) or set(spec["required"]) - set(args):
            raise ToolError("invalid_arguments", "参数缺失或含不支持字段；不能忽略国家等筛选条件。")
        types = {"integer": int, "string": str, "boolean": bool}
        for key, value in args.items():
            rule = spec["properties"][key]
            if type(value) is not types[rule["type"]]:
                raise ToolError("invalid_arguments", f"{key} 类型不正确")
            if "enum" in rule and value not in rule["enum"]:
                raise ToolError("invalid_arguments", f"{key} 取值不支持")
            if "minimum" in rule and not rule["minimum"] <= value <= rule["maximum"]:
                raise ToolError("invalid_arguments", f"{key} 超出范围")

    def monthly_metrics(self, start_month, end_month, allow_incomplete=False):
        for month in (start_month, end_month):
            if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month):
                raise ToolError("invalid_period", "月份格式应为YYYY-MM")
        if start_month > end_month or start_month < "2009-12" or end_month > "2011-12":
            raise ToolError("out_of_range", "数据范围为2009-12至2011-12，不能查询今日或其他年份。")
        rows = self.rows('SELECT * FROM monthly WHERE "月份" BETWEEN ? AND ? ORDER BY "月份"', (start_month, end_month))
        incomplete = [r["月份"] for r in rows if r["是否完整月"] != "1"]
        if incomplete and not allow_incomplete:
            raise ToolError("incomplete_period", "2011-12仅到12月9日。请澄清是否仅查询已记录值；同比建议统一1至11月。")
        revenue = sum((Decimal(r["营收"]) for r in rows), Decimal(0))
        orders = sum(int(r["订单数"]) for r in rows)
        totals = {"revenue_gbp": float(revenue), "orders": orders,
                  "aov_gbp": round(float(revenue / orders), 2) if orders else None}
        return {"start_month": start_month, "end_month": end_month, "totals": totals, "months": rows}, ["monthly"], "SQL历史口径；全部国家，含匿名订单；发票订单数；GBP", ["2011-12为不完整月，非全年可比值"] if incomplete else []

    def compare_years(self, year_a, year_b, start_month, end_month):
        if year_a == year_b or start_month > end_month:
            raise ToolError("invalid_period", "应比较不同年份的同一连续月份范围")
        a = self.monthly_metrics(f"{year_a:04d}-{start_month:02d}", f"{year_a:04d}-{end_month:02d}")[0]
        b = self.monthly_metrics(f"{year_b:04d}-{start_month:02d}", f"{year_b:04d}-{end_month:02d}")[0]
        # AOV同比用未舍入的期间总额/订单数计算，避免先舍入再比较。
        def values(period):
            t = period["totals"]
            return {"revenue_gbp": t["revenue_gbp"], "orders": t["orders"], "aov_gbp": t["revenue_gbp"] / t["orders"]}
        av, bv = values(a), values(b)
        change = {key: round((bv[key] / av[key] - 1) * 100, 4) if av[key] else None for key in av}
        return {"base": a, "comparison": b, "change_pct": change}, ["monthly"], "两年相同月份；SQL口径，GBP，全部国家含匿名", []

    def segment_summary(self, kind):
        return self.rows(f'SELECT * FROM "{kind}"'), [kind], "全期2009-12-01至2011-12-09；SQL历史近似配对口径；RFM/帕累托仅实名，ABC为商品销售贡献", ["销售贡献不等于利润或库存周转；全期分层不能当作历史某年分层"]

    def customer_list(self, sort_by, limit, observation_date):
        if observation_date != "2011-08-31":
            raise ToolError("unsupported_snapshot", "当前只提供2011-08-31的离线名单，无法查询今日或其他观察点名单。")
        column = '"优先级分"' if sort_by == "priority" else '"复购概率"'
        rows = self.rows(f'SELECT * FROM candidates ORDER BY CAST({column} AS REAL) DESC, CAST("Customer_ID" AS INTEGER) ASC LIMIT ?', (limit,))
        # 原CSV的「优先级」属于priority排序，不能作为probability查询的排名。
        rows = [{"查询排名": i, **{k: v for k, v in row.items() if k != "优先级"}} for i, row in enumerate(rows, 1)]
        return {"sort_by": sort_by, "observation_date": observation_date, "customers": rows,
                "tie_break": "分数并列按Customer_ID升序；概率按CSV已导出的四位小数排序"}, ["candidates"], "ML时点快照；2011-08-31日末；未来90天截至2011-11-29；仅有效购买实名客户", ["离线历史名单；未提供联系方式；候选排序的触达收益尚未验证；不代表永久流失", "概率仅保留四位小数，1.0000不代表一定复购；未评估概率校准"]

    def model_report(self, window):
        clause, params = ("", ()) if window == "all" else (" WHERE window = ?", (window,))
        metrics = self.rows("SELECT * FROM metrics" + clause, params)
        lifts = self.rows("SELECT * FROM lift" + clause, params)
        aucs = [float(r["auc"]) for r in metrics if r["model"] == "逻辑回归"]
        return {"metrics": metrics, "lift_by_probability": lifts, "lr_mean_auc": sum(aucs) / len(aucs)}, ["metrics", "lift"], "离线滚动验证W1/W2/W3；概率名单评估", ["AUC不等于准确率；未评估概率校准；提升度不代表发券增量"]

    def metric_definition(self, topic):
        sources = ["metrics", "lift"] if topic in ("auc", "lift") else []
        return {"topic": topic, "definition": DEFINITIONS[topic]}, sources, "项目口径字典；定义为维护的说明，非新增实测结论", []
