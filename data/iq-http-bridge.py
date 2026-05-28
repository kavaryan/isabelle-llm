#!/usr/bin/env python3

import http.server
import os
import socket
import sys


IQ_HOST = "127.0.0.1"
IQ_PORT = 8765
HTTP_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
IQ_AUTH_TOKEN = os.environ.get("IQ_AUTH_TOKEN", "")


def read_line(sock):
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    return data


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        payload = self.rfile.read(length).rstrip(b"\r\n") + b"\n"

        try:
            with socket.create_connection((IQ_HOST, IQ_PORT), timeout=10) as sock:
                if IQ_AUTH_TOKEN:
                    auth = (
                        '{"jsonrpc":"2.0","id":"http-bridge-auth",'
                        '"method":"tools/call","params":{"name":"authenticate",'
                        '"arguments":{"token":"%s"}}}\n'
                    ) % IQ_AUTH_TOKEN.replace("\\", "\\\\").replace('"', '\\"')
                    sock.sendall(auth.encode())
                    read_line(sock)
                sock.sendall(payload)
                data = read_line(sock)
        except Exception as exc:
            body = ('{"error":"%s"}\n' % str(exc).replace('"', '\\"')).encode()
            self.send_response(502)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, _format, *_args):
        return


server = http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
server.serve_forever()
