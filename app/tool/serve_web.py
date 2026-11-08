"""Serve the Flutter web build and forward /api/* to the Parkour backend on the same origin.

The backend has no CORS headers, so the web app calls /api on its own origin instead.
Standard library only.

    flutter build web
    python3 tool/serve_web.py            # http://127.0.0.1:8080, backend at http://127.0.0.1:8000
    python3 tool/serve_web.py --port 8080 --api http://127.0.0.1:8000
"""
import argparse
import http.server
import pathlib
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1] / "build" / "web"
HOP = {"connection", "keep-alive", "transfer-encoding", "content-encoding", "content-length", "host"}


def make_handler(api: str):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(ROOT), **kw)

        def log_message(self, fmt, *args):
            pass

        def _proxy(self):
            url = api + self.path[len("/api"):]
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            req = urllib.request.Request(url, data=body, method=self.command)
            for k, v in self.headers.items():
                if k.lower() not in HOP:
                    req.add_header(k, v)
            try:
                resp = urllib.request.urlopen(req, timeout=120)
                status, headers, data = resp.status, resp.headers, resp.read()
            except urllib.error.HTTPError as e:
                status, headers, data = e.code, e.headers, e.read()
            except urllib.error.URLError:
                status, headers = 502, {}
                data = b'{"error":{"code":"offline","message":"The Parkour backend is not running."}}'
            self.send_response(status)
            for k, v in (headers.items() if hasattr(headers, "items") else []):
                if k.lower() not in HOP:
                    self.send_header(k, v)
            if status == 502:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _route(self):
            if self.path.startswith("/api/") or self.path == "/api":
                return self._proxy()
            if self.command != "GET":
                return self.send_error(405)
            # single-page app: unknown paths fall back to index.html
            target = ROOT / self.path.split("?")[0].lstrip("/")
            if self.path != "/" and not target.exists():
                self.path = "/index.html"
            return super().do_GET()

        do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _route

    return Handler


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--api", default="http://127.0.0.1:8000")
    a = ap.parse_args()
    if not (ROOT / "index.html").exists():
        raise SystemExit("No build/web yet. Run: flutter build web")
    srv = http.server.ThreadingHTTPServer((a.host, a.port), make_handler(a.api.rstrip("/")))
    print(f"Parkour web on http://{a.host}:{a.port}  (api -> {a.api})", flush=True)
    srv.serve_forever()
