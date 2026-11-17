#!/usr/bin/env python3
"""Check an existing VLESS outbound using a temporary loopback-only proxy."""
import json
import os
import re
import socket
import subprocess
import tempfile
import time


runtime = os.environ.get("CONDUCTOR_CHECK_RUNTIME", "/tmp/sing-box-1.14.0-darwin-arm64/sing-box")
source = os.environ.get("CONDUCTOR_CHECK_CONFIG", os.path.expanduser("~/sing-box/config.json"))
target = os.environ.get("CONDUCTOR_CHECK_TARGET", "https://chatgpt.com/cdn-cgi/trace")
if target not in {"https://chatgpt.com/cdn-cgi/trace", "https://www.apple.com/"}:
    raise SystemExit("Target must be the predefined ChatGPT or Apple test URL")
with open(source, encoding="utf-8") as stream:
    source_config = json.load(stream)
matches = [outbound for outbound in source_config.get("outbounds", [])
           if outbound.get("tag") == "chatgpt-vless" and outbound.get("type") == "vless"]
if len(matches) != 1:
    raise SystemExit("Expected exactly one chatgpt-vless outbound")

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

fixture = {
    "log": {"level": "error"},
    "inbounds": [{"type": "http", "listen": "127.0.0.1", "listen_port": port}],
    "outbounds": [matches[0]],
    "route": {"final": "chatgpt-vless"},
}
with tempfile.TemporaryDirectory(prefix="conductor-vless-check-") as directory:
    config = os.path.join(directory, "config.json")
    fd = os.open(config, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(fixture, stream)
    check = subprocess.run([runtime, "check", "-c", config], capture_output=True)
    if check.returncode:
        raise SystemExit("Isolated sing-box configuration check failed")
    process = subprocess.Popen([runtime, "run", "-c", config], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("Temporary proxy exited before listening")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Temporary proxy did not start")
        result = subprocess.run([
            "curl", "--silent", "--show-error", "--output", "/dev/null", "--write-out", "%{http_code}",
            "--connect-timeout", "10", "--max-time", "25", "--noproxy", "", "--proxy", f"http://127.0.0.1:{port}",
            target,
        ], capture_output=True, text=True)
        print(f"curl exit={result.returncode}; HTTP status={result.stdout or 'unavailable'}")
        if result.returncode or result.stdout == "000":
            if result.stderr:
                print(result.stderr.strip())
            raise SystemExit("VLESS HTTPS request failed; no credentials were printed")
    finally:
        if process.poll() is None:
            process.terminate()
        _stdout, stderr = process.communicate(timeout=5)
        secrets = []
        def collect(value):
            if isinstance(value, dict):
                for child in value.values(): collect(child)
            elif isinstance(value, list):
                for child in value: collect(child)
            elif isinstance(value, str) and len(value) >= 6:
                secrets.append(value)
        collect(matches[0])
        for secret in sorted(secrets, key=len, reverse=True):
            stderr = stderr.replace(secret, "[redacted]")
        stderr = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "[ip]", stderr)
        for line in stderr.splitlines():
            if "ERROR" in line or "FATAL" in line:
                print("sing-box:", line)
