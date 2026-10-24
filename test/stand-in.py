"""A local stand-in of the Opsgenie Alert and Heartbeat API for test/notify-test.sh.

It records each request as one JSON line (method, path, query, the Authorization header, the body)
and answers as the mode file says: "ok" (202 with a request id), "401" (a refused key), "429" (too
many requests), or "500" or "503" (a server error with an HTML body). A list such as "500,ok" gives
one answer for each request, in order; the last one stays.
"""
import http.server
import json
import sys
import urllib.parse

port, folder = int(sys.argv[1]), sys.argv[2]


def mode():
    with open(folder + "/mode") as f:
        answers = f.read().strip().split(",")
    if len(answers) > 1:
        with open(folder + "/mode", "w") as f:
            f.write(",".join(answers[1:]))
    return answers[0]


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_any(self):
        url = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else ""
        with open(folder + "/requests", "a") as f:
            f.write(json.dumps({"method": self.command, "path": url.path, "query": url.query,
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        m = mode()
        if m in ("500", "503"):
            data = b"<html>Bad gateway</html>"
            self.send_response(int(m))
            self.send_header("Content-Type", "text/html")
        elif m == "429":
            data = json.dumps({"message": "Too many requests", "took": 0.001, "requestId": "req-429"}).encode()
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
        elif m == "401":
            data = json.dumps({"message": "Key format is not valid!", "took": 0.001, "requestId": "req-401"}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
        else:
            result = "PONG - Heartbeat received" if url.path.endswith("/ping") else "Request will be processed"
            data = json.dumps({"result": result, "took": 0.01, "requestId": "req-1"}).encode()
            self.send_response(202)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Request-Id", "req-1")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = handle_any
    do_POST = handle_any

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
