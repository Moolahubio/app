#!/usr/bin/env python3
"""Test-only proxy in front of the local dev backend (http://localhost:8787).

Starts GET /api/dashboard/summary and GET /api/activity answers but never
finishes them: 200, then one space of a chunked body every 5 s for HOLD
seconds, then the connection drops. The app's 20 s idle timeout never fires;
its 60 s resource timeout ends the read. Every other request passes straight
through. Listens on 127.0.0.1 only. Logs nothing (no paths, headers or bodies).
Used by HomeFlowUITests.testASlowServerShowsSkeletonsThenOneErrorAndNoAmounts
(ui-test.sh starts it and sets TEST_RUNNER_MH_HOME_SLOW_API).

    python3 slow-api-proxy.py PORT HOLD [PORT_FILE]

PORT 0 picks a free port; with PORT_FILE the port in use is written there once
the proxy is listening.
"""
import http.client
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8797
HOLD = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
UPSTREAM = ("localhost", 8787)
HELD = ("/api/dashboard/summary", "/api/activity")
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "host", "content-length"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _hold(self):
        # Answer 200 at once, then trickle one space of a chunked JSON body
        # every 5 s, so the app's idle timeout (20 s) never fires and only its
        # resource timeout (60 s) ends the read; then drop the connection.
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        deadline = time.time() + HOLD
        try:
            while time.time() < deadline:
                self.wfile.write(b"1\r\n \r\n")
                self.wfile.flush()
                time.sleep(5)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        if self.command == "GET" and self.path.startswith(HELD):
            self._hold()
            return
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        conn = http.client.HTTPConnection(*UPSTREAM, timeout=30)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _forward


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as port_file:
            port_file.write(str(server.server_address[1]))
    server.serve_forever()
