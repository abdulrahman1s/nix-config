#!/usr/bin/env python3
"""End-to-end routing and cloud-payload leakage tests with local mock endpoints."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROUTER_SOURCE = Path(os.environ.get("PRIVACY_ROUTER_SOURCE", Path(__file__).resolve().parent.parent / "privacy-router.py"))
CAPTURE: dict[str, list[dict]] = {"local": [], "cloud": []}


class MockHandler(BaseHTTPRequestHandler):
    role = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        payload = json.loads(self.rfile.read(length))
        CAPTURE[self.role].append(payload)
        if self.role == "local" and "response_format" in payload:
            text = json.dumps(payload).lower()
            if "classifier_malformed" in text:
                content = "public"
            elif "classifier_hedged" in text:
                content = json.dumps({"verdict": "public", "reason": "probably safe"})
            else:
                verdict = "private" if "authenticated account" in text else "public"
                content = json.dumps({"verdict": verdict})
        else:
            content = f"{self.role.upper()}_OK"
        auto_route = payload.get("model") in {"model-auto", "public-fast", "public-strong"}
        response_model = payload.get("model")
        selected_model = "openrouter/google/gemini-3.8-flash"
        if payload.get("stream"):
            chunks = [
                {"object": "chat.completion.chunk", "model": response_model, "choices": [{"index": 0, "delta": {"content": content}, "finish_reason": None}]},
                {"object": "chat.completion.chunk", "model": response_model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ]
            if auto_route:
                chunks.append({
                    "object": "chat.completion.chunk",
                    "model": response_model,
                    "choices": [],
                    "provider_specific_fields": {"openrouter_metadata": {"selected_model": selected_model}},
                })
                chunks.append({
                    "object": "chat.completion.chunk",
                    "model": response_model,
                    "choices": [],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
                })
            body = b"".join(b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks) + b"data: [DONE]\n\n"
            self.send_response(200)
            if self.headers.get("X-OpenRouter-Metadata"):
                self.send_header("x-captured-openrouter-metadata", self.headers["X-OpenRouter-Metadata"])
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        message = {"role": "assistant", "content": content}
        if auto_route:
            message["provider_specific_fields"] = {"model": selected_model}
        body = json.dumps({"model": response_model, "choices": [{"message": message}]}).encode()
        self.send_response(200)
        if self.headers.get("X-OpenRouter-Metadata"):
            self.send_header("x-captured-openrouter-metadata", self.headers["X-OpenRouter-Metadata"])
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def server(port: int, role: str) -> ThreadingHTTPServer:
    handler = type(f"{role.title()}Handler", (MockHandler,), {"role": role})
    instance = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=instance.serve_forever, daemon=True).start()
    return instance


def request(messages: list[dict], **extra: object) -> dict:
    payload = {"model": "privacy-auto", "messages": messages, **extra}
    req = Request(
        "http://127.0.0.1:14100/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
    )
    return json.loads(urlopen(req, timeout=10).read())


def stream_request(messages: list[dict]) -> str:
    payload = {"model": "privacy-auto", "messages": messages, "stream": True}
    req = Request(
        "http://127.0.0.1:14100/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
    )
    return urlopen(req, timeout=10).read().decode()


def wait_ready() -> None:
    for _ in range(100):
        try:
            urlopen("http://127.0.0.1:14100/health", timeout=0.2)
            return
        except Exception:
            time.sleep(0.05)
    raise RuntimeError("privacy router did not start")


def main() -> None:
    local = server(14101, "local")
    cloud = server(14102, "cloud")
    env = os.environ | {
        "LOCAL_LLM_URL": "http://127.0.0.1:14101/v1",
        "LITELLM_URL": "http://127.0.0.1:14102/v1",
        "LOCAL_MODEL_NAME": "Qwen3.5-9B",
        "CLOUD_FAST_MODEL_NAME": "openrouter/auto",
        "CLOUD_STRONG_MODEL_NAME": "openrouter/auto",
        "MODEL_SWITCHES": json.dumps({
            "auto": "auto",
            "gpt:cheap": "gpt-5.6-luna",
            "gpt:balanced": "gpt-5.6-terra",
            "gpt:best": "gpt-5.6-sol",
            "deepseek:cheap": "deepseek-v4.1-flash",
            "deepseek:balanced": "deepseek-v4-pro",
            "deepseek:best": "deepseek-v4-pro",
        }),
        "PRIVACY_ROUTER_HOST": "127.0.0.1",
        "PRIVACY_ROUTER_PORT": "14100",
    }
    process = subprocess.Popen([sys.executable, str(ROUTER_SOURCE)], env=env)
    try:
        wait_ready()

        response = request([{"role": "user", "content": "What is the capital of Japan?"}])
        assert CAPTURE["cloud"][-1]["model"] == "public-fast"
        cloud_system_prompt = CAPTURE["cloud"][-1]["messages"][0]["content"]
        assert "precise, reserved, methodical" in cloud_system_prompt
        assert "what remains uncertain" in cloud_system_prompt
        assert CAPTURE["cloud"][-1]["extra_headers"] == {"X-OpenRouter-Metadata": "enabled"}
        assert response["choices"][0]["message"]["content"].endswith("[cloud:google/gemini-3.8-flash]"), response
        classifier = next(payload for payload in CAPTURE["local"] if "response_format" in payload)
        assert classifier["chat_template_kwargs"] == {"enable_thinking": False}
        assert "publicly accessible" in classifier["messages"][0]["content"]

        classifier_count = sum("response_format" in payload for payload in CAPTURE["local"])
        response = request([{"role": "user", "content": "Explain HTTP status 204."}], model="public-bypass")
        assert sum("response_format" in payload for payload in CAPTURE["local"]) == classifier_count
        assert response["choices"][0]["message"]["content"].endswith("[cloud:google/gemini-3.8-flash]")

        cloud_count_before_private_bypass = len(CAPTURE["cloud"])
        request([{"role": "user", "content": "Summarize my email account."}], model="public-bypass")
        assert len(CAPTURE["cloud"]) == cloud_count_before_private_bypass
        assert CAPTURE["local"][-1]["model"] == "local"

        vision_content = [
            {"type": "text", "text": "Describe this screenshot."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,aGVsbG8="}},
        ]
        response = request([{"role": "user", "content": vision_content}], model="vision-online")
        assert CAPTURE["cloud"][-1]["model"] == "public-fast"
        assert "image_url" in json.dumps(CAPTURE["cloud"][-1])
        assert response["choices"][0]["message"]["content"].endswith("[cloud:google/gemini-3.8-flash]")

        cloud_count = len(CAPTURE["cloud"])
        tool_secret = "sk-TOOL_SCHEMA_SECRET_1234567890"
        request(
            [{"role": "user", "content": "Say hello."}],
            tools=[{
                "type": "function",
                "function": {
                    "name": "login_form",
                    "description": f"Use API key: {tool_secret} for a private form.",
                    "parameters": {"type": "object", "properties": {"password": {"type": "string"}}},
                },
            }],
        )
        assert len(CAPTURE["cloud"]) == cloud_count
        assert CAPTURE["local"][-1]["model"] == "local"
        assert tool_secret not in json.dumps(CAPTURE["local"][-1])

        streamed = stream_request([{"role": "user", "content": "What is the capital of Egypt?"}])
        assert "[cloud:google/gemini-3.8-flash]" in streamed

        response = request([
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi\n\n[cloud:google/gemini-3.8-flash]"},
            {"role": "user", "content": "What is the capital of Egypt?"},
        ])
        assert "[cloud:" not in response["choices"][0]["message"]["content"]

        response = request([{"role": "user", "content": "Design a complex distributed system and compare tradeoffs."}])
        assert CAPTURE["cloud"][-1]["model"] == "public-strong"
        assert response["choices"][0]["message"]["content"].endswith("[cloud:google/gemini-3.8-flash]")

        response = request([{"role": "user", "content": "model:gpt Explain binary trees."}])
        assert CAPTURE["cloud"][-1]["model"] == "model-gpt-balanced"
        assert "model:gpt" not in json.dumps(CAPTURE["cloud"][-1]).lower()
        assert "model:gpt" not in json.dumps(CAPTURE["local"][-1]).lower()
        assert response["choices"][0]["message"]["content"].endswith("[cloud:gpt-5.6-terra]")

        flag_aliases = {
            "low": "cheap", "cheap": "cheap", "fast": "cheap",
            "mid": "balanced", "balance": "balanced",
            "smart": "best", "complex": "best", "best": "best",
        }
        for flag, expected_tier in flag_aliases.items():
            request([{"role": "user", "content": f"model:gpt:{flag} Say hello."}])
            assert CAPTURE["cloud"][-1]["model"] == f"model-gpt-{expected_tier}"

        response = request([{"role": "user", "content": "model:auto Pick an appropriate model."}])
        assert CAPTURE["cloud"][-1]["model"] == "model-auto"
        assert "model:auto" not in json.dumps(CAPTURE["cloud"][-1]).lower()
        assert response["choices"][0]["message"]["content"].endswith("[cloud:google/gemini-3.8-flash]")

        cloud_count = len(CAPTURE["cloud"])
        local_count = len(CAPTURE["local"])
        response = request([{"role": "user", "content": "model:local Explain binary trees."}])
        assert len(CAPTURE["cloud"]) == cloud_count
        assert len(CAPTURE["local"]) == local_count + 1
        assert CAPTURE["local"][-1]["model"] == "local"
        assert "response_format" not in CAPTURE["local"][-1]
        assert "model:local" not in json.dumps(CAPTURE["local"][-1]).lower()
        assert response["choices"][0]["message"]["content"].endswith("[local:Qwen3.5-9B]")

        response = request([
            {"role": "user", "content": "model:gpt:low Say hello."},
            {"role": "assistant", "content": "Hello\n\n[cloud:gpt-5.6-luna]"},
            {"role": "user", "content": "Now explain a tree."},
        ])
        assert CAPTURE["cloud"][-1]["model"] == "model-gpt-cheap"
        assert "[cloud:" not in response["choices"][0]["message"]["content"]

        response = request([
            {"role": "user", "content": "model:gpt:low Say hello."},
            {"role": "assistant", "content": "Hello\n\n[cloud:gpt-5.6-luna]"},
            {"role": "user", "content": "model:deepseek:best Analyze a complex algorithm."},
        ])
        assert CAPTURE["cloud"][-1]["model"] == "model-deepseek-best"
        assert response["choices"][0]["message"]["content"].endswith("[cloud:deepseek-v4-pro]")

        cloud_count = len(CAPTURE["cloud"])
        response = request([{"role": "user", "content": "model:gpt:best Analyze my email account."}])
        assert len(CAPTURE["cloud"]) == cloud_count
        assert "model:gpt:best" not in json.dumps(CAPTURE["local"][-1]).lower()
        assert response["choices"][0]["message"]["content"].endswith("[local:Qwen3.5-9B]")

        cloud_count = len(CAPTURE["cloud"])
        response = request([{"role": "user", "content": "Analyze my email account and private messages."}])
        reng = CAPTURE["local"][-1]
        assert reng["model"] == "local" and len(CAPTURE["cloud"]) == cloud_count
        assert reng["max_tokens"] == 4096
        assert reng["chat_template_kwargs"] == {"enable_thinking": False}
        assert response["choices"][0]["message"]["content"].endswith("[local:Qwen3.5-9B]")

        for unsafe_classifier_output in ("CLASSIFIER_MALFORMED", "CLASSIFIER_HEDGED"):
            request([{"role": "user", "content": unsafe_classifier_output}])
            assert len(CAPTURE["cloud"]) == cloud_count
            assert CAPTURE["local"][-1]["model"] == "local"

        classifier_count = sum("response_format" in payload for payload in CAPTURE["local"])
        request([{"role": "user", "content": "x" * 24_001}])
        assert len(CAPTURE["cloud"]) == cloud_count
        assert sum("response_format" in payload for payload in CAPTURE["local"]) == classifier_count

        response = request([
            {"role": "user", "content": "Earlier private request"},
            {"role": "assistant", "content": "LOCAL_OK\n\n[local:Qwen3.5-9B]"},
            {"role": "user", "content": "What is the capital of France?"},
        ])
        assert len(CAPTURE["cloud"]) == cloud_count
        assert "[local:Qwen3.5-9B]" not in json.dumps(CAPTURE["local"][-1])
        assert "[local:" not in response["choices"][0]["message"]["content"]

        response = request([
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi\n\n[cloud:glm-5.3-flash]"},
            {"role": "user", "content": "Analyze my email account."},
        ])
        assert response["choices"][0]["message"]["content"].endswith("[local:Qwen3.5-9B]")

        sticky_canary = "PRIVATE_CONVERSATION_CANARY_42a9"
        request([
            {"role": "user", "content": f"Analyze my email account. {sticky_canary}"},
            {"role": "assistant", "content": "LOCAL_OK"},
            {"role": "user", "content": "Now explain red-black trees."},
        ])
        assert CAPTURE["local"][-1]["model"] == "local"
        assert len(CAPTURE["cloud"]) == cloud_count
        assert sticky_canary not in json.dumps(CAPTURE["cloud"])

        remember_canary = "REMEMBER_CANARY_0cd7"
        request([
            {"role": "user", "content": f"Remember that my preferred editor is Zed. {remember_canary}"},
            {"role": "assistant", "content": "LOCAL_OK"},
            {"role": "user", "content": "What is 2 + 2?"},
        ])
        assert CAPTURE["local"][-1]["model"] == "local"
        assert len(CAPTURE["cloud"]) == cloud_count
        assert remember_canary not in json.dumps(CAPTURE["cloud"])

        private_canary = "PRIVATE_MEMORY_CANARY_8f52"
        request([
            {"role": "system", "content": f"MEMORY.md: {private_canary}"},
            {"role": "user", "content": "Explain red-black trees."},
        ])
        captured = json.dumps(CAPTURE["cloud"][-1])
        assert private_canary not in captured and "MEMORY.md" not in captured

        public_canary = "CLOUD_SAFE_CONTEXT_CANARY_71c1"
        request([{"role": "user", "content": f"Use this cloud-safe fact: {public_canary}"}])
        assert public_canary in json.dumps(CAPTURE["cloud"][-1])

        secret_canary = "api_key=sk-SECRET_CANARY_1234567890"
        cloud_count = len(CAPTURE["cloud"])
        request([{"role": "user", "content": f"Please inspect {secret_canary}"}])
        assert len(CAPTURE["cloud"]) == cloud_count
        assert secret_canary not in json.dumps(CAPTURE["cloud"])
        assert secret_canary not in json.dumps(CAPTURE["local"])
        assert "[REDACTED_SECRET]" in json.dumps(CAPTURE["local"][-1])

        cloud_count = len(CAPTURE["cloud"])
        request([{"role": "user", "content": "Compare these tabs"}, {"role": "tool", "content": "authenticated account dashboard"}])
        assert len(CAPTURE["cloud"]) == cloud_count

        request([
            {"role": "user", "content": "Compare these tabs"},
            {"role": "tool", "content": "authenticated account dashboard"},
            {"role": "assistant", "content": "LOCAL_OK"},
            {"role": "user", "content": "Now explain binary trees."},
        ])
        assert len(CAPTURE["cloud"]) == cloud_count
        assert CAPTURE["local"][-1]["model"] == "local"

        request([{"role": "user", "content": "Summarize this page"}, {"role": "tool", "content": "A public encyclopedia article about NixOS."}])
        assert len(CAPTURE["cloud"]) == cloud_count + 1

        for bad_messages in ([], ["not a message"]):
            try:
                request(bad_messages)
                raise AssertionError("Malformed messages were accepted")
            except HTTPError as error:
                assert error.code == 400

        cloud.shutdown()
        cloud.server_close()
        try:
            request([{"role": "user", "content": "Explain HTTP 204."}], model="public-bypass")
            raise AssertionError("Unavailable cloud endpoint was accepted")
        except HTTPError as error:
            assert error.code == 503
            assert json.loads(error.read())["error"]["message"] == "Model endpoint is unavailable."

        print("privacy routing: locally classified public, sticky-private-local: PASS")
        print("payload isolation: memory, browser-private content, credentials: PASS")
    finally:
        process.terminate()
        process.wait(timeout=5)
        local.shutdown()
        cloud.shutdown()


if __name__ == "__main__":
    main()
