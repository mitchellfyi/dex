"""HTTP server helpers for localhost test fixtures."""

from http.server import ThreadingHTTPServer
from socketserver import TCPServer


class LocalThreadingHTTPServer(ThreadingHTTPServer):
    """Bind a local HTTP server without performing a reverse-DNS lookup."""

    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]
