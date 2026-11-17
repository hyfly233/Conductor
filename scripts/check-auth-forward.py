#!/usr/bin/env python3
"""Verify authenticated HTTP and SOCKS outbound forwarding on loopback."""
import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time


RUNTIME = os.environ.get("CONDUCTOR_CHECK_RUNTIME", "/tmp/conductor-runtime-1.14.0/sing-box-1.14.0-darwin-arm64/sing-box")


class Handler(http.server.BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        type(self).requests += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"conductor-auth-ok")

    def log_message(self, *_args):
        pass


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def ready(port, process):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("sing-box exited before listening")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("sing-box did not start listening")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
processes = []
try:
    with tempfile.TemporaryDirectory() as directory:
        upstream_port = unused_port()
        config = {
            "log": {"level": "info"},
            "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": upstream_port,
                          "users": [{"username": "user", "password": "secret"}]}],
            "outbounds": [{"type": "direct", "tag": "direct"}],
        }

        def start(name, value, port):
            path = os.path.join(directory, name + ".json")
            with open(path, "w", encoding="utf-8") as output:
                json.dump(value, output)
            subprocess.run([RUNTIME, "check", "-c", path], check=True)
            process = subprocess.Popen([RUNTIME, "run", "-c", path])
            processes.append(process)
            ready(port, process)

        start("upstream", config, upstream_port)
        for kind in ("http", "socks"):
            for password in ("secret", "wrong"):
                port = unused_port()
                outbound = {"type": kind, "tag": "upstream", "server": "127.0.0.1", "server_port": upstream_port,
                            "username": "user", "password": password}
                front = {"log": {"level": "error"}, "inbounds": [{"type": "http", "listen": "127.0.0.1", "listen_port": port}],
                         "outbounds": [outbound], "route": {"final": "upstream"}}
                start(kind + "-" + password, front, port)
                before = Handler.requests
                result = subprocess.run(["curl", "--silent", "--show-error", "--fail", "--max-time", "5", "--noproxy", "", "--proxytunnel",
                                         "--proxy", f"http://127.0.0.1:{port}", f"http://127.0.0.1:{server.server_port}/"],
                                        capture_output=True)
                if password == "secret":
                    assert result.returncode == 0 and result.stdout == b"conductor-auth-ok" and Handler.requests == before + 1, kind
                    print(f"Authenticated {kind} outbound forwarded HTTP successfully")
                else:
                    assert result.returncode != 0 and Handler.requests == before, kind
                    print(f"Invalid {kind} credentials rejected before reaching destination")
finally:
    for process in processes:
        process.terminate()
    for process in processes:
        process.wait(timeout=5)
    server.shutdown()
    server.server_close()
