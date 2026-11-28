// 竖屏提示 + 旋转重排的浏览器验收脚本（无第三方依赖，走原生 CDP）。
//
// 用法：
//   1) python -m http.server 8123 --directory build/web
//   2) msedge --headless=new --remote-debugging-port=9222 about:blank
//   3) node dev/web_rotate_check.mjs
//
// 分两段验：
//   A. 加载中（限速 600KB/s）：竖屏只看到提示 + 进度条在屏内、贴底 12%；
//      加载中来回转 2 次，提示层与进度条都不错位、进度不回退。
//   B. 引擎跑起来之后：来回转 3 次，每次断言 canvas 填满视口、缓冲按 dpr 放大、
//      提示层按方向显示/隐藏；最后截菜单图。
// 结果写 .workbuddy/web_rotate.txt，截图写 .workbuddy/web_*.png。

import { writeFileSync, mkdirSync } from 'node:fs';

const CDP = 'http://127.0.0.1:9222';
const URL_UNDER_TEST = 'http://127.0.0.1:8123/index.html';
const OUT_DIR = '.workbuddy';

const PORTRAIT = { width: 390, height: 844 };
const LANDSCAPE = { width: 844, height: 390 };
const DPR = 2;

const lines = [];
const fails = [];

function log(s) {
	lines.push(s);
	process.stdout.write(s + '\n');
}

function check(name, ok, detail) {
	if (ok) {
		log(`[OK]   ${name}${detail ? '  ' + detail : ''}`);
	} else {
		log(`[FAIL] ${name}${detail ? '  ' + detail : ''}`);
		fails.push(name);
	}
}

function sleep(ms) {
	return new Promise((r) => setTimeout(r, ms));
}

class Cdp {
	constructor(ws) {
		this.ws = ws;
		this.id = 0;
		this.pending = new Map();
		ws.addEventListener('message', (ev) => {
			const msg = JSON.parse(ev.data);
			if (msg.id !== undefined) {
				const p = this.pending.get(msg.id);
				if (p) {
					this.pending.delete(msg.id);
					if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
					else p.resolve(msg.result);
				}
			}
		});
	}

	send(method, params = {}) {
		const id = ++this.id;
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
			this.ws.send(JSON.stringify({ id, method, params }));
		});
	}

	async evaluate(expression) {
		const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
		if (r.exceptionDetails) throw new Error('evaluate 异常: ' + JSON.stringify(r.exceptionDetails));
		return r.result.value;
	}

	async shot(name) {
		const r = await this.send('Page.captureScreenshot', { format: 'png' });
		writeFileSync(`${OUT_DIR}/${name}.png`, Buffer.from(r.data, 'base64'));
	}
}

const PROBE = `(() => {
	const rot = document.getElementById('rotate');
	const bar = document.getElementById('loadbar');
	const c = document.getElementById('canvas');
	const rect = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]; };
	const head = rot ? rot.querySelector('.headline') : null;
	const tip = document.getElementById('rotate-percent');
	const prog = document.getElementById('status-progress');
	return {
		vw: window.innerWidth,
		vh: window.innerHeight,
		dpr: window.devicePixelRatio,
		readyState: document.readyState,
		rotateDisplay: rot ? getComputedStyle(rot).display : 'absent',
		rotateRect: rect(rot),
		headline: head ? head.textContent : null,
		tip: tip ? tip.textContent : null,
		barRect: rect(bar),
		canvasAttr: c ? [c.width, c.height] : null,
		canvasStyle: c ? [c.style.width, c.style.height] : null,
		canvasRect: rect(c),
		statusPresent: !!document.getElementById('status'),
		notice: document.getElementById('status') ? document.getElementById('status').classList.contains('notice') : false,
		noticeText: (document.getElementById('status-notice') || {}).textContent || '',
		progressValue: prog ? prog.value : null,
	};})()`;

async function setOrientation(cdp, size, type, angle) {
	await cdp.send('Emulation.setDeviceMetricsOverride', {
		width: size.width, height: size.height, deviceScaleFactor: DPR, mobile: true,
		screenOrientation: { type, angle },
	});
	// 尺寸变更后浏览器会派发 resize / orientationchange，给页面一点时间落定
	await sleep(700);
}

function inside(rect, vw, vh) {
	if (!rect) return false;
	const [x, y, w, h] = rect;
	return x >= -1 && y >= -1 && x + w <= vw + 1 && y + h <= vh + 1;
}

async function waitFor(cdp, predicate, timeoutMs, stepMs = 300) {
	const start = Date.now();
	let last = null;
	while (Date.now() - start < timeoutMs) {
		try {
			last = await cdp.evaluate(PROBE);
			if (predicate(last)) return last;
		} catch (e) { /* 导航中页面上下文会被替换，重试即可 */ }
		await sleep(stepMs);
	}
	return last;
}

async function main() {
	mkdirSync(OUT_DIR, { recursive: true });

	const targets = await (await fetch(`${CDP}/json/list`)).json();
	const pages = targets.filter((t) => t.type === 'page');
	const page = pages.find((t) => t.url === 'about:blank') || pages[0];
	if (!page) throw new Error('没有可用的 page target');

	const ws = new WebSocket(page.webSocketDebuggerUrl);
	await new Promise((res, rej) => {
		ws.addEventListener('open', res);
		ws.addEventListener('error', rej);
	});
	const cdp = new Cdp(ws);

	await cdp.send('Page.enable');
	await cdp.send('Runtime.enable');
	await cdp.send('Network.enable');
	// 本地回环几百毫秒就拉完 39MB wasm，#loadbar 会被立刻移除，
	// 根本来不及验证"加载中"的版式。限到 600KB/s 模拟手机网络，
	// 顺便把"边加载边旋转"这件最容易被忽略的事真跑一遍。
	await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
	await cdp.send('Network.emulateNetworkConditions', {
		offline: false, latency: 120,
		downloadThroughput: 600 * 1024, uploadThroughput: 300 * 1024,
	});

	// ---------- A. 加载中：竖屏 ----------
	await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
	await cdp.send('Page.navigate', { url: URL_UNDER_TEST + '?t=' + Date.now() });

	let p = await waitFor(cdp, (q) => q.readyState === 'complete', 20000);
	check('竖屏：提示层可见', p.rotateDisplay === 'flex', 'display=' + p.rotateDisplay);
	check('竖屏：提示层铺满视口',
		p.rotateRect && p.rotateRect[2] >= p.vw - 1 && p.rotateRect[3] >= p.vh - 1,
		'rotate=' + JSON.stringify(p.rotateRect) + ' viewport=' + p.vw + 'x' + p.vh);
	check('竖屏：大字文案正确', p.headline === '请把手机横过来', 'headline=' + p.headline);
	check('竖屏：进度条在屏内', inside(p.barRect, p.vw, p.vh), 'loadbar=' + JSON.stringify(p.barRect));
	check('竖屏：进度条贴底 12%',
		p.barRect && Math.abs((p.vh - (p.barRect[1] + p.barRect[3])) - p.vh * 0.12) <= 4,
		'底部留白=' + (p.barRect ? p.vh - (p.barRect[1] + p.barRect[3]) : 'null') + ' 期望=' + Math.round(p.vh * 0.12));
	check('竖屏：加载进度有文字反馈', !!p.tip, 'tip=' + p.tip);
	await cdp.shot('web_1_portrait_loading');

	// 收集一个进度值，用来验证"旋转不会把加载重置"
	const beforeRotate = await waitFor(cdp, (q) => q.progressValue > 0, 15000);
	const progressBefore = beforeRotate.progressValue || 0;

	// ---------- A2. 加载中来回转 2 次 ----------
	for (let round = 1; round <= 2; round++) {
		await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);
		const pl = await cdp.evaluate(PROBE);
		check(`加载中第 ${round} 轮·横屏：提示层隐藏`, pl.rotateDisplay === 'none', 'display=' + pl.rotateDisplay);
		check(`加载中第 ${round} 轮·横屏：进度条在屏内`, inside(pl.barRect, pl.vw, pl.vh), 'loadbar=' + JSON.stringify(pl.barRect));

		await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
		const pp = await cdp.evaluate(PROBE);
		check(`加载中第 ${round} 轮·竖屏：提示层回来`, pp.rotateDisplay === 'flex', 'display=' + pp.rotateDisplay);
		check(`加载中第 ${round} 轮·竖屏：进度条在屏内`, inside(pp.barRect, pp.vw, pp.vh), 'loadbar=' + JSON.stringify(pp.barRect));
	}

	const afterRotate = await cdp.evaluate(PROBE);
	check('加载中旋转：进度没有被打回 0',
		afterRotate.statusPresent === false || afterRotate.progressValue === null || afterRotate.progressValue >= progressBefore,
		`旋转前=${progressBefore} 旋转后=${afterRotate.progressValue}`);
	await cdp.shot('web_2_portrait_loading_rotated');

	// ---------- B. 解除限速，等引擎真正跑起来 ----------
	await cdp.send('Network.emulateNetworkConditions', {
		offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1,
	});
	await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);

	// 引擎 init 之后 canvas 才会有真实尺寸（之前是默认 300x150）
	p = await waitFor(cdp, (q) => q.canvasAttr && q.canvasAttr[0] > 1000, 180000, 500);
	check('横屏：canvas 已由引擎接管（尺寸 > 1000）',
		p.canvasAttr && p.canvasAttr[0] > 1000, 'attr=' + JSON.stringify(p.canvasAttr));
	check('横屏：canvas 宽度对齐窗口',
		p.canvasStyle && Math.abs(parseFloat(p.canvasStyle[0]) - p.vw) <= 2,
		'canvasStyle=' + JSON.stringify(p.canvasStyle) + ' vw=' + p.vw);
	check('横屏：canvas 高度对齐窗口',
		p.canvasStyle && Math.abs(parseFloat(p.canvasStyle[1]) - p.vh) <= 2,
		'canvasStyle=' + JSON.stringify(p.canvasStyle) + ' vh=' + p.vh);
	check('横屏：canvas 缓冲按 dpr 放大',
		p.canvasAttr && Math.abs(p.canvasAttr[0] - p.vw * p.dpr) <= 4,
		'attr=' + JSON.stringify(p.canvasAttr) + ' 期望宽=' + p.vw * p.dpr);

	// ---------- B2. 引擎运行中来回转 3 次 ----------
	for (let round = 1; round <= 3; round++) {
		await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
		const pp = await cdp.evaluate(PROBE);
		check(`第 ${round} 轮·竖屏：提示层出现`, pp.rotateDisplay === 'flex', 'display=' + pp.rotateDisplay);

		await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);
		const pl = await cdp.evaluate(PROBE);
		check(`第 ${round} 轮·横屏：提示层隐藏`, pl.rotateDisplay === 'none', 'display=' + pl.rotateDisplay);
		check(`第 ${round} 轮·横屏：canvas 尺寸正确`,
			pl.canvasAttr && Math.abs(pl.canvasAttr[0] - pl.vw * pl.dpr) <= 4 && Math.abs(pl.canvasAttr[1] - pl.vh * pl.dpr) <= 4,
			'attr=' + JSON.stringify(pl.canvasAttr) + ' 期望=' + [pl.vw * pl.dpr, pl.vh * pl.dpr]);
		check(`第 ${round} 轮·横屏：canvas 填满视口（无黑边/留白）`,
			pl.canvasRect && Math.abs(pl.canvasRect[2] - pl.vw) <= 2 && Math.abs(pl.canvasRect[3] - pl.vh) <= 2,
			'canvas rect=' + JSON.stringify(pl.canvasRect));
	}

	// ---------- C. 等加载完成，确认进得了菜单 ----------
	let loaded = false;
	for (let i = 0; i < 240; i++) {
		await sleep(500);
		const q = await cdp.evaluate(PROBE);
		if (q.notice) {
			log('加载失败提示：' + q.noticeText.replace(/\n/g, ' | '));
			break;
		}
		if (!q.statusPresent) {
			loaded = true;
			break;
		}
	}
	check('横屏：加载完成并进入游戏', loaded, loaded ? '' : '120 秒内没有走完加载');
	await sleep(1500);
	await cdp.shot('web_3_landscape_menu');

	// ---------- D. 进游戏后再竖一次 ----------
	await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
	const after = await cdp.evaluate(PROBE);
	check('加载后再竖屏：提示层仍然出现', after.rotateDisplay === 'flex', 'display=' + after.rotateDisplay);
	// 加载完的竖屏层不再说"加载完成"，而是说暂停：见 dev/web_pause_check.mjs
	check('加载后再竖屏：文案变成横屏继续', after.tip && after.tip.indexOf('横屏') >= 0, 'tip=' + after.tip);
	await cdp.shot('web_4_portrait_after_load');

	log('');
	log(`=== ${fails.length === 0 ? '全部通过' : '存在问题'}（失败 ${fails.length} 项）===`);
	if (fails.length) fails.forEach((f) => log('  FAIL ' + f));

	writeFileSync(`${OUT_DIR}/web_rotate.txt`, lines.join('\n'), 'utf-8');
	ws.close();
}

await main();
