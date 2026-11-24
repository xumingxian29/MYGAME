#!/usr/bin/env python3
"""本地预览 Godot Web 导出产物。

不能直接双击 index.html：浏览器禁止 file:// 下加载 WebAssembly 与 .pck，
必须经 HTTP 提供。用法：

    python serve.py            # 默认 http://127.0.0.1:8080
    python serve.py 9000       # 换端口
    python serve.py 8080 --lan # 监听 0.0.0.0，同一 Wi-Fi 的手机可以打开

Gzip 是必需的：index.wasm 未压缩约 38MB，压缩后约 10MB。
压缩结果按 mtime 缓存在 build/web/.gzcache/，第二次启动不再重算。
"""

import gzip
import http.server
import os
import socket
import socketserver
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build", "web")
CACHE = os.path.join(ROOT, ".gzcache")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 8080
# 默认只听本机：顺手开个端口不该让同网段的人都能扫到。要在手机上试玩再加 --lan。
LAN = "--lan" in sys.argv


def lan_ip() -> str:
    """拿本机在局域网里的地址。连一个外网地址只是为了让系统选路由，不会真的发包。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()

# 浏览器对 wasm 的 MIME 校验很严格，application/wasm 写错会直接拒绝实例化
EXTRA_TYPES = {
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".js": "text/javascript",
    ".json": "application/json",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".html": "text/html; charset=utf-8",
}

COMPRESSIBLE = {".wasm", ".js", ".pck", ".html", ".json", ".svg"}
MIN_SIZE = 1024


def compressed(path: str, ext: str) -> bytes:
    """按 mtime 缓存压缩结果，避免每次启动都重压 38MB 的 wasm。"""
    st = os.stat(path)
    cache_name = "%s_%d_%d.gz" % (os.path.basename(path), int(st.st_mtime), st.st_size)
    cache_path = os.path.join(CACHE, cache_name)
    if os.path.exists(cache_path):
        with open(cache_path, "rb") as f:
            return f.read()
    with open(path, "rb") as f:
        raw = f.read()
    packed = gzip.compress(raw, compresslevel=6)
    try:
        os.makedirs(CACHE, exist_ok=True)
        with open(cache_path, "wb") as f:
            f.write(packed)
    except OSError:
        pass
    return packed


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "MYGAME"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def guess_type(self, path):
        ext = os.path.splitext(path)[1].lower()
        return EXTRA_TYPES.get(ext) or super().guess_type(path)

    def do_GET(self):
        if self.path in ("/", ""):
            self.path = "/index.html"
        path = self.translate_path(self.path)

        if os.path.isdir(path):
            return super().do_GET()
        if not os.path.isfile(path):
            self.send_error(404)
            return

        ext = os.path.splitext(path)[1].lower()
        accepts_gzip = "gzip" in self.headers.get("Accept-Encoding", "")
        use_gzip = accepts_gzip and ext in COMPRESSIBLE and os.path.getsize(path) >= MIN_SIZE

        try:
            body = compressed(path, ext) if use_gzip else open(path, "rb").read()
        except OSError:
            self.send_error(500)
            return

        self.send_response(200)
        self.send_header("Content-Type", self.guess_type(path))
        # 关键：这里必须是实际发出的字节数。之前发压缩数据却报原始长度，
        # 浏览器会以 ERR_CONTENT_LENGTH_MISMATCH 中止整个 wasm 加载。
        self.send_header("Content-Length", str(len(body)))
        if use_gzip:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        # 开发期禁用缓存，避免改了代码还看到旧包
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # 只报 4xx/5xx，正常请求不刷屏
        if args and str(args[1] if len(args) > 1 else "").startswith(("4", "5")):
            super().log_message(fmt, *args)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if not os.path.isdir(ROOT):
        sys.exit("找不到 %s，请先导出：\n"
                 '  godot --headless --path . --export-release "Web" build/web/index.html' % ROOT)
    host = "0.0.0.0" if LAN else "127.0.0.1"
    with Server((host, PORT), Handler) as httpd:
        print("游戏地址： http://127.0.0.1:%d/" % PORT)
        if LAN:
            print("手机（同一 Wi-Fi）： http://%s:%d/" % (lan_ip(), PORT))
            print("提示：Windows 防火墙可能拦截首次访问，弹窗要选「允许」")
        print("按 Ctrl+C 停止")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")
