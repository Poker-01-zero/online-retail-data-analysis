"""从已有导出表构建本地 SQLite 分析快照，不修改 MySQL 或 ML 数据。"""

import csv
import hashlib
import json
import sqlite3
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = Path(__file__).resolve().parent / "data" / "retail.sqlite"
SOURCES = {
    "monthly": "data/exports/01_月度趋势.csv",
    "rfm": "data/exports/04_RFM八类客户.csv",
    "abc": "data/exports/03_商品ABC.csv",
    "pareto": "data/exports/05_帕累托十分位.csv",
    "metrics": "ml/outputs/metrics.csv",
    "lift": "ml/outputs/lift_table.csv",
    "candidates": "ml/outputs/churn_list.csv",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_database(path=DB_PATH):
    path = Path(path)
    # 先检查所有源文件，避免文件缺失时覆盖现有快照。
    for relative in SOURCES.values():
        if not (ROOT / relative).is_file():
            raise FileNotFoundError(f"缺少 {relative}；请先准备 SQL 导出并运行 python ml/run.py")
    path.parent.mkdir(parents=True, exist_ok=True)
    manifest = {}
    with closing(sqlite3.connect(path)) as conn, conn:
        for table, relative in SOURCES.items():
            source = ROOT / relative
            with source.open(encoding="utf-8-sig", newline="") as file:
                reader = csv.DictReader(file)
                fields = reader.fieldnames
                rows = list(reader)
            # 表名、列名仅来自受信任的固定源文件，不来自用户或模型。
            columns = ",".join('"' + name.replace('"', '""') + '" TEXT' for name in fields)
            conn.execute(f'DROP TABLE IF EXISTS "{table}"')
            conn.execute(f'CREATE TABLE "{table}" ({columns})')
            placeholders = ",".join("?" for _ in fields)
            conn.executemany(f'INSERT INTO "{table}" VALUES ({placeholders})',
                             [[row[field] for field in fields] for row in rows])
            manifest[table] = {"source": relative, "sha256": digest(source), "rows": len(rows)}
        conn.execute("DROP TABLE IF EXISTS manifest")
        conn.execute("CREATE TABLE manifest (table_name TEXT PRIMARY KEY, metadata TEXT)")
        conn.executemany("INSERT INTO manifest VALUES (?, ?)",
                         [(key, json.dumps(value, ensure_ascii=False)) for key, value in manifest.items()])
    return manifest


def connect(path=DB_PATH):
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError("请先运行 python -m agent.build_db")
    conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only=ON")
    return conn


def verify_database(path=DB_PATH):
    with closing(connect(path)) as conn:
        manifest = {row[0]: json.loads(row[1]) for row in conn.execute("SELECT * FROM manifest")}
    if set(manifest) != set(SOURCES):
        raise ValueError("分析快照结构已变化，请重跑 python -m agent.build_db")
    for table, relative in SOURCES.items():
        if not (ROOT / relative).is_file() or digest(ROOT / relative) != manifest[table]["sha256"]:
            raise ValueError(f"{relative} 已变化，请重跑 python -m agent.build_db")
    return manifest
