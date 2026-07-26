#!/usr/bin/env python3
"""Portal server: phục vụ portal.html + proxy /api/* -> Kong Admin API (same-origin, tránh CORS).
Chạy trên máy có Kong Admin. DEV:  python3 serve-portal.py
  ENV: PORT (mặc định 8003), KONG_ADMIN (mặc định http://localhost:8001)
"""
import os, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8003"))
ADMIN = os.environ.get("KONG_ADMIN", "http://localhost:8001").rstrip("/")
HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "portal.html")

class H(BaseHTTPRequestHandler):
    def _page(self):
        try:
            data = open(HTML, "rb").read()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        except Exception as e:
            self.send_error(500, str(e))

    def _proxy(self):
        # /api/<path>  ->  ADMIN/<path>
        target = ADMIN + self.path[4:]
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(target, data=body, method=self.command)
        ct = self.headers.get("Content-Type")
        if ct: req.add_header("Content-Type", ct)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read(); code = r.status; ctype = r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            data = e.read(); code = e.code; ctype = e.headers.get("Content-Type", "application/json")
        except Exception as e:
            data = ('{"message":"proxy error: %s"}' % e).encode(); code = 502; ctype = "application/json"
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"): return self._page()
        if self.path.startswith("/api/"): return self._proxy()
        self.send_error(404)
    def do_POST(self):   self._proxy() if self.path.startswith("/api/") else self.send_error(404)
    def do_PUT(self):    self._proxy() if self.path.startswith("/api/") else self.send_error(404)
    def do_PATCH(self):  self._proxy() if self.path.startswith("/api/") else self.send_error(404)
    def do_DELETE(self): self._proxy() if self.path.startswith("/api/") else self.send_error(404)
    def log_message(self, *a): pass

if __name__ == "__main__":
    print(f"Portal:  http://0.0.0.0:{PORT}/   (Kong Admin: {ADMIN})")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
