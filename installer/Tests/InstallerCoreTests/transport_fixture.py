"""Isolated HTTP fixture. Never connects to a database or records real events."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time
import socket

MANIFEST = (Path(__file__).parent / "Fixtures/cursor-user.json").read_bytes()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        key = self.path.rsplit("/", 1)[-1]
        if key == "redirect":
            self.send_response(302)
            self.send_header("Location", "https://example.invalid/stolen-intent")
            self.end_headers()
            return
        if key == "expired":
            self.send_response(410)
            self.end_headers()
            return
        self.send_response(200)
        if key == "oversize":
            self.send_header("Content-Length", str(8 * 1024 * 1024))
        elif key != "stream":
            self.send_header("Content-Length", str(len(MANIFEST)))
        self.end_headers()
        try:
            if key == "slow":
                time.sleep(4)
            if key == "stream":
                self.wfile.write(b" " * (4 * 1024 * 1024 + 1))
            elif key == "oversize":
                self.wfile.write(b" " * (8 * 1024 * 1024))
            else:
                self.wfile.write(MANIFEST)
        except (BrokenPipeError, ConnectionResetError):
            pass

class IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6

server = IPv6Server(("::1", 8000), Handler)
print("ready", flush=True)
server.serve_forever()
