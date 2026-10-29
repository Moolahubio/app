#!/usr/bin/env python3
"""Test-only fault proxy in front of the local dev backend (http://localhost:8787).

    python3 fault-api-proxy.py PORT_FILE MODE_FILE

Listens on 127.0.0.1 only, on a free port written to PORT_FILE. Before every
request it reads MODE_FILE (missing or empty means "pass"):

  pass                everything goes straight through.
  wallet-unavailable  GET /api/wallet is answered with what the server sends
                      when its balance read fails: availableCents 0 and
                      balanceUnavailable true (lib/onchainBalances.ts).
  drop                money POSTs (/wallet/deposit, /goals/*/allocate,
                      /goals/*/release, /goals/*/delete,
                      /circles/*/contribute) are forwarded (the move happens)
                      and then the connection is closed with no response.
  garble              money POSTs are forwarded and answered 200 with a body
                      that is not JSON.
  gateway-timeout     money POSTs are forwarded (the move happens) and then
                      answered 504 with a gateway's HTML page, as a load
                      balancer does when the app server answers too late.

Used by QAExploratoryUITests (uncertain outcomes, a failed balance read, a
gateway 504, View activity over Pay in, DESIGN.md v2 J0.7 and J0.8):
ui-test.sh starts it and sets TEST_RUNNER_MH_QA_FAULT_API and
TEST_RUNNER_MH_QA_FAULT_MODE_FILE. Only the test that set a mode is running
through it; the app under every other test talks to the backend directly.
Logs nothing: no paths, headers or bodies.
"""
import http.client
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = ("localhost", 8787)
PORT_FILE = sys.argv[1]
MODE_FILE = sys.argv[2]
MONEY = re.compile(r"^/api/(wallet/deposit|goals/[^/]+/(allocate|release|delete)|circles/[^/]+/contribute)$")
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "host", "content-length"}


def mode():
    try:
        with open(MODE_FILE) as handle:
            return handle.read().strip() or "pass"
    except OSError:
        return "pass"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _upstream(self, body):
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        connection = http.client.HTTPConnection(*UPSTREAM, timeout=60)
        connection.request(self.command, self.path, body=body, headers=headers)
        response = connection.getresponse()
        data = response.read()
        status = response.status
        out_headers = [(k, v) for k, v in response.getheaders() if k.lower() not in HOP]
        connection.close()
        return status, out_headers, data

    def _reply(self, status, headers, data):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        current = mode()
        path = self.path.split("?", 1)[0]
        status, headers, data = self._upstream(body)
        if current == "wallet-unavailable" and self.command == "GET" and path == "/api/wallet" and status == 200:
            payload = json.loads(data)
            payload["availableCents"] = 0
            payload["balanceUnavailable"] = True
            data = json.dumps(payload).encode()
        elif self.command == "POST" and MONEY.match(path) and current == "gateway-timeout":
            data = b"<html><body><h1>504 Gateway Time-out</h1></body></html>"
            headers = [("Content-Type", "text/html")]
            status = 504
        elif self.command == "POST" and MONEY.match(path) and current in ("drop", "garble"):
            if current == "drop":
                self.close_connection = True
                try:
                    self.connection.shutdown(2)
                except OSError:
                    pass
                return
            data = b"<html>not json</html>"
            headers = [("Content-Type", "text/html")]
            status = 200
        self._reply(status, headers, data)

    do_GET = _handle
    do_POST = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_PUT = _handle


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
