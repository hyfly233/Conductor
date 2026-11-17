#!/usr/bin/env python3
"""Exercise mixed-proxy authentication against an isolated loopback mock."""
import base64
import os
import socket
import subprocess
import threading


def read_exact(conn, count):
    data = b""
    while len(data) < count:
        part = conn.recv(count - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def serve(conn, truncated=False):
    with conn:
        conn.settimeout(5)
        try:
            first = read_exact(conn, 1)
            if first == b"\x05":
                count = read_exact(conn, 1)[0]
                methods = read_exact(conn, count)
                if 2 not in methods:
                    conn.sendall(b"\x05\xff")
                    return
                conn.sendall(b"\x05\x02")
                version, size = read_exact(conn, 2)
                username = read_exact(conn, size)
                password = read_exact(conn, read_exact(conn, 1)[0])
                valid = version == 1 and username == b"test" and password == b"secret"
                conn.sendall(bytes([1, 0 if valid else 1]))
                if valid:
                    read_exact(conn, 4)
                    conn.sendall(b"\x05\x00\x00\x01" if truncated else b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01")
            else:
                request = first
                while b"\r\n\r\n" not in request and len(request) < 8192:
                    request += read_exact(conn, 1)
                expected = b"Proxy-Authorization: Basic " + base64.b64encode(b"test:secret")
                code = b"200 OK" if expected in request.split(b"\r\n") else b"407 Proxy Authentication Required"
                conn.sendall(b"HTTP/1.1 " + code + b"\r\n\r\n")
        except (OSError, EOFError):
            pass


with socket.socket() as listener, socket.socket() as truncated_listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(0.2)
    truncated_listener.bind(("127.0.0.1", 0))
    truncated_listener.listen()
    truncated_listener.settimeout(0.2)
    env = os.environ.copy()
    env["CONDUCTOR_CHECK_AUTH_PROXY"] = "127.0.0.1:" + str(listener.getsockname()[1])
    env["CONDUCTOR_CHECK_TRUNCATED_PROXY"] = "127.0.0.1:" + str(truncated_listener.getsockname()[1])
    process = subprocess.Popen(["/tmp/conductor-operation-checks"], env=env)
    while process.poll() is None:
        for sock, truncated in ((listener, False), (truncated_listener, True)):
            try:
                conn, _ = sock.accept()
                threading.Thread(target=serve, args=(conn, truncated), daemon=True).start()
            except socket.timeout:
                pass
    raise SystemExit(process.returncode)
