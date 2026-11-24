"""手机横屏 + 触摸模拟下验收 H5 版：截图 + 点击 + 拖拽摇杆。

用法：python dev/mobile_check.py
产物：build/mobile_*.png
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

import websocket

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
URL = os.environ.get("MV_URL", "http://127.0.0.1:8080/")
PROFILE = os.path.join(os.environ["TEMP"], "edge-cdp-mygame-mobile")
OUT = os.path.join("build")
PORT = 9333

W = int(os.environ.get("MV_W", 844))
H = int(os.environ.get("MV_H", 390))  # 默认 iPhone 14 横屏的 CSS 像素
MOBILE = os.environ.get("MV_MOBILE", "1") == "1"
TOUCH = os.environ.get("MV_TOUCH", "1") == "1"
PREFIX = os.environ.get("MV_PREFIX", "mobile")


def log(*a):
    print(*a, flush=True)


class CDP:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=90)
        self.n = 0

    def send(self, method, **params):
        self.n += 1
        mid = self.n
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method} -> {msg['error']}")
                return msg.get("result", {})

    def eval(self, expr):
        r = self.send("Runtime.evaluate", expression=expr, returnByValue=True)
        return r.get("result", {}).get("value")

    def shot(self, path):
        data = self.send("Page.captureScreenshot", format="png")["data"]
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))
        log("  shot ->", path)

    def touch(self, kind, x, y, tid=0):
        points = [] if kind == "touchEnd" else [{"x": x, "y": y, "id": tid, "radiusX": 8, "radiusY": 8, "force": 1}]
        self.send("Input.dispatchTouchEvent", type=kind, touchPoints=points)


LOAD_TIMEOUT = int(os.environ.get("MV_LOAD_TIMEOUT", "60"))


def wait_for(cdp, expr, timeout=60, label=""):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if cdp.eval(expr):
                return True
        except Exception:
            pass
        time.sleep(0.3)
    log("  TIMEOUT waiting:", label or expr)
    return False


def main():
    os.makedirs(OUT, exist_ok=True)
    subprocess.run(["taskkill", "/F", "/IM", "msedge.exe"], capture_output=True)
    time.sleep(1)
    proc = subprocess.Popen([
        EDGE,
        f"--remote-debugging-port={PORT}",
        f"--user-data-dir={PROFILE}",
        "--remote-allow-origins=*",
        "--no-first-run", "--no-default-browser-check",
        "--disable-features=Translate",
        f"--window-size={W + 20},{H + 120}",
        "about:blank",
    ])
    log("edge pid", proc.pid)

    ws_url = None
    for _ in range(60):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/list", timeout=2) as r:
                items = json.load(r)
            pages = [i for i in items if i["type"] == "page"]
            if pages:
                ws_url = pages[0]["webSocketDebuggerUrl"]
                break
        except Exception:
            pass
        time.sleep(0.5)
    if not ws_url:
        log("no devtools target")
        return 1

    cdp = CDP(ws_url)
    cdp.send("Page.enable")
    cdp.send("Runtime.enable")
    cdp.send("Emulation.setDeviceMetricsOverride",
             width=W, height=H, deviceScaleFactor=3 if MOBILE else 1, mobile=MOBILE)
    cdp.send("Emulation.setTouchEmulationEnabled", enabled=TOUCH, maxTouchPoints=5)
    if MOBILE:
        cdp.send("Emulation.setUserAgentOverride",
                 userAgent="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                           "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
    log("emulation: %dx%d mobile=%s touch=%s" % (W, H, MOBILE, TOUCH))
    cdp.send("Page.addScriptToEvaluateOnNewDocument", source="""
window.__errs = [];
const _ce = console.error;
window.__logs = [];
const _cl = console.log;
console.log = function(...a) { window.__logs.push(a.join(' ')); _cl.apply(console, a); };
console.error = function(...a) { window.__errs.push(a.join(' ')); _ce.apply(console, a); };
window.addEventListener('error', e => window.__errs.push('ERR ' + e.message));
window.addEventListener('unhandledrejection', e => window.__errs.push('REJ ' + e.reason));
""")
    cdp.send("Page.navigate", url=URL)

    ok = wait_for(cdp, "(() => { const c = document.querySelector('canvas');"
                       " return c && c.width > 300 && window.__godotStarted === undefined ? c.width > 300 : c.width > 300; })()",
                  timeout=LOAD_TIMEOUT, label="canvas")
    if not ok:
        cdp.shot(os.path.join(OUT, PREFIX + "_fail.png"))
        return 2
    log("canvas ready")
    # 引擎挂载后再等一会儿：首帧编译着色器 + 建 UI
    time.sleep(14)
    cdp.shot(os.path.join(OUT, PREFIX + "_1_menu.png"))

    log("console:", cdp.eval("navigator.maxTouchPoints"))

    # 后续步骤的坐标由外部脚本给出（第一次先只截菜单图定位按钮）
    steps = json.loads(os.environ.get("MOBILE_STEPS", "[]"))
    for step in steps:
        kind = step["kind"]
        if kind == "tap":
            x, y = step["x"], step["y"]
            cdp.touch("touchStart", x, y)
            time.sleep(0.08)
            cdp.touch("touchEnd", x, y)
            log("  tap", x, y)
        elif kind == "drag":
            x0, y0 = step["x0"], step["y0"]
            x1, y1 = step["x1"], step["y1"]
            cdp.touch("touchStart", x0, y0)
            time.sleep(0.06)
            for i in range(1, 6):
                cdp.touch("touchMove", x0 + (x1 - x0) * i / 5, y0 + (y1 - y0) * i / 5)
                time.sleep(0.03)
            time.sleep(step.get("hold", 1.2))
            cdp.touch("touchEnd", x1, y1)
            log("  drag", x0, y0, "->", x1, y1)
        elif kind == "screenshot":
            cdp.shot(os.path.join(OUT, step["name"]))
        elif kind == "wait":
            time.sleep(step["seconds"])
        elif kind == "click":
            x, y = step["x"], step["y"]
            cdp.send("Input.dispatchMouseEvent", type="mouseMoved", x=x, y=y)
            cdp.send("Input.dispatchMouseEvent", type="mousePressed", x=x, y=y, button="left", clickCount=1)
            time.sleep(0.06)
            cdp.send("Input.dispatchMouseEvent", type="mouseReleased", x=x, y=y, button="left", clickCount=1)
            log("  click", x, y)
        elif kind == "mouse":
            x, y = step["x"], step["y"]
            cdp.send("Input.dispatchMouseEvent", type="mousePressed", x=x, y=y, button="left", clickCount=1)
            time.sleep(0.05)
            cdp.send("Input.dispatchMouseEvent", type="mouseReleased", x=x, y=y, button="left", clickCount=1)
            log("  mouse click", x, y)
        elif kind == "key":
            k = step["key"]
            vk = step.get("vk", 13)
            cdp.send("Input.dispatchKeyEvent", type="keyDown", key=k, code=k,
                     windowsVirtualKeyCode=vk, nativeVirtualKeyCode=vk, text=step.get("text", ""))
            time.sleep(0.05)
            cdp.send("Input.dispatchKeyEvent", type="keyUp", key=k, code=k,
                     windowsVirtualKeyCode=vk, nativeVirtualKeyCode=vk)
            log("  key", k)
        elif kind == "js":
            log("  js ->", cdp.eval(step["expr"]))
        elif kind == "hold_drag":
            # 按下 -> 拖 -> 拖到一半截图 -> 松手，用来看摇杆与角色的中间态
            x0, y0 = step["x0"], step["y0"]
            x1, y1 = step["x1"], step["y1"]
            cdp.touch("touchStart", x0, y0)
            time.sleep(0.05)
            for i in range(1, 6):
                cdp.touch("touchMove", x0 + (x1 - x0) * i / 5, y0 + (y1 - y0) * i / 5)
                time.sleep(0.03)
            time.sleep(step.get("hold", 0.8))
            cdp.shot(os.path.join(OUT, step["name"]))
            cdp.touch("touchEnd", x1, y1)
            log("  hold_drag ->", step["name"])

    logs = cdp.eval("JSON.stringify((window.__logs || []).slice(-40))")
    log("console logs:", logs)
    errs = cdp.eval("JSON.stringify(window.__errs || [])")
    log("console errors:", errs)
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
