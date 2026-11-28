// H5 移动端（手机横屏 844x390 @2x）实机渲染验收 + 截图。
//
// 用法：
//   1) python serve.py 8080
//   2) msedge --headless=new --remote-debugging-port=9222 about:blank
//   3) node dev/web_mobile_shot.mjs
//
// 验的是三件只有真浏览器才看得见的事：
//   A. 剧情屏右上角的「跳过」在 844x390 里没被圆角/边缘裁掉，且点得中；
//   B. 点下去真的跳过（state 从 STORY 回到 PLAYING）；
//   C. 战斗界面的 HUD 在手机上没糊成一团。
// 截图写 .workbuddy/web_m_*.png，结果写 .workbuddy/web_mobile.txt。

import { writeFileSync, mkdirSync } from 'node:fs';

const CDP = 'http://127.0.0.1:9222';
// 默认打本地导出；要验线上站点就 WEB_URL=https://xumingxian29.github.io/MYGAME/index.html node dev/web_mobile_shot.mjs
const URL_UNDER_TEST = process.env.WEB_URL || 'http://127.0.0.1:8080/index.html';
const OUT_DIR = '.workbuddy';
const LANDSCAPE = { width: 844, height: 390 };
const DPR = 2;

const S_MENU = 0;
const S_PLAYING = 1;
const S_LEVEL_UP = 2;
const S_STORY = 7;

const lines = [];
const fails = [];
const log = (s) => { lines.push(s); process.stdout.write(s + '\n'); };
function check(name, ok, detail) {
	if (ok) log(`[OK]   ${name}${detail ? '  ' + detail : ''}`);
	else { log(`[FAIL] ${name}${detail ? '  ' + detail : ''}`); fails.push(name); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Cdp {
	constructor(ws) {
		this.ws = ws; this.id = 0; this.pending = new Map();
		ws.addEventListener('message', (ev) => {
			const msg = JSON.parse(ev.data);
			if (msg.id === undefined) return;
			const p = this.pending.get(msg.id);
			if (!p) return;
			this.pending.delete(msg.id);
			if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
			else p.resolve(msg.result);
		});
	}
	send(method, params = {}) {
		const id = ++this.id;
		return new Promise((res, rej) => { this.pending.set(id, { resolve: res, reject: rej }); this.ws.send(JSON.stringify({ id, method, params })); });
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
	async click(x, y) {
		const base = { x, y, button: 'left', clickCount: 1 };
		await this.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...base, button: 'none' });
		await this.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base });
		await sleep(70);
		await this.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base });
	}
	async press(key, code, keyCode) {
		const base = { key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode };
		await this.send('Input.dispatchKeyEvent', { type: 'keyDown', ...base, text: key });
		await sleep(50);
		await this.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base });
	}
}

const STATE_PROBE = `(() => { const raw = window.__nsState; if (!raw) return null;
	try { return JSON.parse(raw); } catch (e) { return null; } })()`;

async function readState(cdp) { return cdp.evaluate(STATE_PROBE); }

async function waitState(cdp, pred, timeoutMs) {
	const start = Date.now();
	while (Date.now() - start < timeoutMs) {
		try {
			const s = await readState(cdp);
			if (s && pred(s)) return s;
		} catch (e) { /* 导航中 */ }
		await sleep(120);
	}
	return null;
}

async function main() {
	mkdirSync(OUT_DIR, { recursive: true });
	const targets = await (await fetch(`${CDP}/json/list`)).json();
	const pages = targets.filter((t) => t.type === 'page');
	const page = pages.find((t) => t.url === 'about:blank') || pages[0];
	if (!page) throw new Error('没有可用的 page target');

	const ws = new WebSocket(page.webSocketDebuggerUrl);
	await new Promise((res, rej) => { ws.addEventListener('open', res); ws.addEventListener('error', rej); });
	const cdp = new Cdp(ws);

	await cdp.send('Page.enable');
	await cdp.send('Runtime.enable');
	await cdp.send('Network.enable');
	await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });

	// 只开 mobile 视口，**不开 setTouchEmulationEnabled**：开了之后 CDP 会把
	// dispatchMouseEvent 合成的鼠标事件丢掉（四种输入方式全试过，一个都到不了引擎），
	// 于是所有断言都会以"点空"失败。手机上 Godot 走 emulate_mouse_from_touch，
	// 触摸最终也是变成鼠标事件进 Control，所以鼠标路径覆盖的是同一条链路。
	await cdp.send('Emulation.setDeviceMetricsOverride', {
		width: LANDSCAPE.width, height: LANDSCAPE.height, deviceScaleFactor: DPR, mobile: true,
		screenOrientation: { type: 'landscapePrimary', angle: 90 },
	});

	await cdp.send('Page.navigate', { url: URL_UNDER_TEST + '?p=' + Date.now() });

	let loaded = false;
	for (let i = 0; i < 400; i++) {
		await sleep(300);
		try {
			if (await cdp.evaluate(`!document.getElementById('status')`)) { loaded = true; break; }
		} catch (e) { /* 还在导航 */ }
	}
	check('加载完成', loaded, loaded ? '' : '120 秒内没走完加载');
	await sleep(1500);

	const menu = await waitState(cdp, (s) => s.state === S_MENU, 8000);
	check('进到菜单', menu !== null, menu ? 'state=' + menu.state : 'null');
	await cdp.shot('web_m_1_menu');

	// 布局信息：canvas 是否填满视口（有黑边说明缩放算错了）
	const geo = await cdp.evaluate(`(() => {
		const c = document.querySelector('canvas');
		const r = c ? c.getBoundingClientRect() : null;
		return { vw: innerWidth, vh: innerHeight, dpr: devicePixelRatio,
			canvas: r ? { x: r.x, y: r.y, w: Math.round(r.width), h: Math.round(r.height) } : null };
	})()`);
	log('  视口 ' + geo.vw + 'x' + geo.vh + ' dpr=' + geo.dpr + ' canvas=' + JSON.stringify(geo.canvas));
	check('canvas 填满视口', geo.canvas && Math.abs(geo.canvas.w - geo.vw) < 2 && Math.abs(geo.canvas.h - geo.vh) < 2,
		JSON.stringify(geo.canvas));

	// 点「开始游戏」。菜单压缩后面板高度固定、内容包在 ScrollContainer 里，
	// 按钮位置随内容变化——写死 (348,284) 已经翻车过一次（难度行上线后点空）。
	// 改为网格扫描：844x390 实测按钮可点区约 x 264~420 / y 254~277（CSS），
	// 35×11 的网格必落其中；扫描可能顺带切了难度/点了随机昵称，对本组断言没有影响。
	let started = null;
	const hits = [];
	for (let y = 254; y <= 276; y += 11) for (let x = 270; x <= 410; x += 35) hits.push([x, y]);
	for (const [px, py] of hits) {
		await cdp.click(px, py);
		started = await waitState(cdp, (s) => s.state !== S_MENU, 800);
		if (started) { log(`  用 (${px}, ${py}) 点进了游戏`); break; }
	}
	check('点开始进了游戏', started !== null, started ? 'state=' + started.state : '九宫格全部点空');

	// 开局就是剧情屏（State.STORY）：这是要验的那一屏
	const story = await waitState(cdp, (s) => s.state === S_STORY, 6000);
	check('开局先播剧情', story !== null, story ? 'state=' + story.state : '没有停在 STORY');
	await sleep(2600);            // 让逐字显示跑一段，看排版而不是空屏
	await cdp.shot('web_m_2_story');

	// 跳过键的位置：960x540 逻辑坐标 (860..938, 22..60) → 844x390 视口
	// 缩放 844/960 = 0.879 → x 756..824, y 19..52。取中心点。
	const SKIP = { x: Math.round((938 - 39) * (844 / 960)), y: Math.round((22 + 19) * (390 / 540)) };
	log(`  跳过键按逻辑坐标折算到视口 (${SKIP.x}, ${SKIP.y})`);
	await cdp.click(SKIP.x, SKIP.y);
	const afterSkip = await waitState(cdp, (s) => s.state === S_PLAYING, 4000);
	check('右上角跳过键点得中（真的跳过）', afterSkip !== null,
		afterSkip ? 'state=' + afterSkip.state : '点了还在 STORY');

	// 战斗中：先是新手提示 + 横幅，等两秒让它落定再拍
	await sleep(2200);
	const play = await readState(cdp);
	check('跳过之后进战斗', play && play.state === S_PLAYING, play ? 'state=' + play.state : 'null');
	await cdp.shot('web_m_3_play');

	// 战斗待一会儿，看怪堆起来之后的画面（HUD + 摇杆 + 血条）
	await sleep(5000);
	await cdp.shot('web_m_4_battle');

	log('');
	log(fails.length === 0 ? '==== 全部通过' : `==== ${fails.length} 项失败`);
	writeFileSync(`${OUT_DIR}/web_mobile.txt`, lines.join('\n') + '\n');
	ws.close();
	process.exit(fails.length === 0 ? 0 : 1);
}

main().catch((e) => {
	log('ERROR ' + e.message);
	writeFileSync(`${OUT_DIR}/web_mobile.txt`, lines.join('\n') + '\n');
	process.exit(1);
});
