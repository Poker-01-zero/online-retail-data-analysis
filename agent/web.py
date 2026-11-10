"""本地演示：python -m agent.web，然后打开 http://127.0.0.1:8765。"""

import argparse
import json
import webbrowser
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .runtime import Agent
from .tools import ToolBox

DIRECTORY = Path(__file__).resolve().parent


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, data, content_type="application/json; charset=utf-8"):
        if not isinstance(data, bytes):
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def local_request(self):
        hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        return self.headers.get("Host") in hosts and self.headers.get("Origin") in (None, *("http://" + host for host in hosts))

    def do_GET(self):
        if not self.local_request():
            return self.reply(403, {"error": "仅接受本地访问"})
        if self.path == "/":
            return self.reply(200, (DIRECTORY / "index.html").read_bytes(), "text/html; charset=utf-8")
        if self.path == "/health":
            return self.reply(200, {"ok": True, "mode": "historical-read-only"})
        return self.reply(404, {"error": "未找到"})

    def do_POST(self):
        if not self.local_request():
            return self.reply(403, {"error": "仅接受本地访问"})
        if self.path != "/api/chat":
            return self.reply(404, {"error": "未找到"})
        if self.headers.get_content_type() != "application/json":
            return self.reply(415, {"error": "请求格式应为JSON"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 65536:
                return self.reply(413, {"error": "请求大小超出范围"})
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict) or not isinstance(payload.get("history", []), list):
                raise ValueError("请求格式错误")
            result = Agent().ask(payload.get("question"), payload.get("history"))
            log_dir = DIRECTORY / "traces"
            log_dir.mkdir(exist_ok=True)
            (log_dir / (datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".json")).write_text(
                json.dumps({"question": payload["question"], **result}, ensure_ascii=False, indent=2), encoding="utf-8")
            self.reply(200 if result["status"] != "error" else 502, result)
        except (ValueError, TypeError, AttributeError):
            self.reply(400, {"error": "问题或会话格式错误"})
        except (RuntimeError, OSError) as exc:
            self.reply(502, {"error": str(exc)})

    def log_message(self, format, *args):
        # 不把问题或工具返回写入控制台HTTP日志；完整调用另存本地trace。
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--open", action="store_true", help="启动服务后自动打开浏览器")
    args = parser.parse_args()
    ToolBox()  # 启动时检查数据快照，避免打开页面后才发现缺文件。
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"电商分析助手：http://127.0.0.1:{args.port}，按 Ctrl+C 停止", flush=True)
    if args.open:
        webbrowser.open(f"http://127.0.0.1:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
