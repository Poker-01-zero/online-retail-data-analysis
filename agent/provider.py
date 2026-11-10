"""DeepSeek Chat Completions 工具调用适配；仅用标准库，不依赖 Agent 框架。"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def load_env(path=None):
    path = Path(path or Path(__file__).resolve().parent / ".env")
    if path.is_file():
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


class ProviderError(RuntimeError):
    pass


class DeepSeekClient:
    def __init__(self):
        load_env()
        self.base_url = os.getenv("AGENT_BASE_URL", "https://api.deepseek.com").rstrip("/")
        self.model = os.getenv("AGENT_MODEL", "deepseek-flash")
        self.key = os.getenv("AGENT_API_KEY", "")
        # 只对同一家官方服务复用既有 Claude Code 环境令牌，不读取用户配置文件。
        old_host = urllib.parse.urlsplit(os.getenv("ANTHROPIC_BASE_URL", "")).hostname
        target = urllib.parse.urlsplit(self.base_url)
        if not self.key and old_host == target.hostname == "api.deepseek.com":
            self.key = os.getenv("ANTHROPIC_AUTH_TOKEN", "")
        if target.scheme != "https" or target.username or target.password or target.query or target.fragment:
            raise ProviderError("AGENT_BASE_URL 必须是无嵌入凭证、无查询参数的 HTTPS API 地址")
        if not self.key:
            raise ProviderError("未配置模型密钥。请复制 agent/.env.example 为 agent/.env 并填写 AGENT_API_KEY。")

    def complete(self, messages, tools):
        body = {"model": self.model, "messages": messages, "tools": tools,
                "tool_choice": "auto", "temperature": 0, "max_tokens": 1600}
        if urllib.parse.urlsplit(self.base_url).hostname == "api.deepseek.com":
            body["thinking"] = {"type": "disabled"}
        request = urllib.request.Request(
            self.base_url + "/chat/completions", data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"})
        # 禁止重定向，避免凭证随意转发到另一个端点。
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=45) as response:
                result = json.load(response)
            return result["choices"][0]["message"], result.get("usage", {})
        except urllib.error.HTTPError as exc:
            raise ProviderError(f"模型服务返回 HTTP {exc.code}；请核对配置、余额或服务状态。") from None
        except (urllib.error.URLError, TimeoutError):
            raise ProviderError("模型服务网络不可达或请求超时；本次未获得完整回答。") from None
        except (ValueError, KeyError, IndexError):
            raise ProviderError("模型服务响应格式不符合 Chat Completions 约定。") from None
