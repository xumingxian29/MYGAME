// 线上构建的加载 / 音频端到端检查（原生 CDP，无第三方依赖）。
//
// 用法：
//   1) python -m http.server 8123 --directory build/web
//   2) msedge --headless=new --remote-debugging-port=9222 about:blank
//   3) node dev/web_audio_check.mjs
//
// 为什么单独写这一份：音效是新加的 Web Audio 路径，headless 下走的是 Dummy 驱动，
// 所以 71 项 audio_check 全绿也**不能证明浏览器里有声**。
// 这一份验三件 headless 验不到的事：
//   ① 音频 worklet 资源真的被浏览器拉下来了；
//   ② AudioContext 在用户手势之后从 suspended 变成 running（自动播放策略放行）；
//   ③ 跑进游戏后没有 JS 异常——Godot 脚本报错在 Web 上是静默的，
//      表现是"某个功能不生效"而不是崩溃，很容易漏到线上。
//
// 结果写 .workbuddy/web_audio.txt，截图写 .workbuddy/web_audio_*.png。

import { writeFileSync, mkdirSync } from 'node:fs';

const CDP = 'http://127.0.0.1:9222';
// 允许用参数覆盖被测地址，直接验线上：
//   node dev/web_audio_check.mjs "https://.../index.html?sharecode=xxx"
const URL_UNDER_TEST = process.argv[2] || 'http://127.0.0.1:8123/index.html';
const OUT_TAG = process.argv[2] ? 'live' : 'local';
const OUT_DIR = '.workbuddy';

const LANDSCAPE = { width: 844, height: 390 };
const DPR = 2;

const S_MENU = 0;
const S_PLAYING = 1;

const lines = [];
const fails = [];

function log(s) {
	lines.push(s);
	process.stdout.write(s + '\n');
}

function check(name, ok, detail) {
	if (ok) log(`[OK]   ${name}${detail ? '  ' + detail : ''}`);
	else {
		log(`[FAIL] ${name}${detail ? '  ' + detail : ''}`);
		fails.push(name);
	}
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Cdp {
	constructor(ws) {
		this.ws = ws;
		this.id = 0;
		this.pending = new Map();
		this.errors = [];
		ws.addEventListener('message', (ev) => {
			const msg = JSON.parse(ev.data);
			if (msg.id !== undefined) {
				const p = this.pending.get(msg.id);
				if (p) {
					this.pending.delete(msg.id);
					if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
					else p.resolve(msg.result);
				}
				return;
			}
			// 事件：JS 异常与 console.error 都收进来。Godot 的 GDScript 报错
			// 在 Web 上会打到 console.error，这是唯一能发现"脚本静默失效"的入口。
			if (msg.method === 'Runtime.exceptionThrown') {
				const d = msg.params.exceptionDetails;
				this.errors.push('EXCEPTION: ' + (d.exception ? d.exception.description : d.text));
			} else if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
				const txt = (msg.params.args || []).map((a) => a.value ?? a.description ?? '').join(' ');
				this.errors.push('console.error: ' + txt);
			} else if (msg.method === 'Network.responseReceived') {
				const st = msg.params.response.status;
				if (st >= 400) (this.badUrls = this.badUrls || []).push(`${st} ${msg.params.response.url}`);
			} else if (msg.method === 'Log.entryAdded' && msg.params.entry.level === 'error') {
				this.errors.push('log: ' + msg.params.entry.text);
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
	async click(x, y) {
		const base = { x, y, button: 'left', clickCount: 1 };
		await this.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...base, button: 'none' });
		await this.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base });
		await sleep(60);
		await this.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base });
	}
}

const STATE_PROBE = `(() => {
	const raw = window.__nsState;
	if (!raw) return null;
	try { return JSON.parse(raw); } catch (e) { return null; }
})()`;

async function readState(cdp) {
	return cdp.evaluate(STATE_PROBE);
}

async function waitState(cdp, predicate, timeoutMs) {
	const start = Date.now();
	while (Date.now() - start < timeoutMs) {
		try {
			const s = await readState(cdp);
			if (s && predicate(s)) return s;
		} catch (e) { /* 导航中上下文会被替换 */ }
		await sleep(150);
	}
	// 超时返回 null，不能返回旧值——否则断言会永远通过
	return null;
}

// 在页面脚本之前注入：包一层 AudioContext 构造函数，把实例记下来。
// 用 addScriptToEvaluateOnNewDocument 而不是导航后再改，
// 是因为 Godot 在启动过程中就会 new AudioContext，之后再包就漏掉了。
const AUDIO_HOOK = `(() => {
	window.__audioCtxs = [];
	const Orig = window.AudioContext || window.webkitAudioContext;
	if (!Orig) { window.__audioCtxsMissing = true; return; }
	const Wrapped = function (...args) {
		const ctx = new Orig(...args);
		window.__audioCtxs.push(ctx);
		return ctx;
	};
	Wrapped.prototype = Orig.prototype;
	window.AudioContext = Wrapped;
	if (window.webkitAudioContext) window.webkitAudioContext = Wrapped;

	// addModule() 的脚本是在 AudioWorkletGlobalScope 里加载的，
	// 不会出现在主文档的 performance resource timing 里 —— 用 performance 查永远是"没有"。
	// 所以直接包 addModule 记下调用与结果，这是"音频管线真的建起来了"最直接的证据。
	window.__workletCalls = [];
	if (window.AudioWorklet && window.AudioWorklet.prototype.addModule) {
		const origAdd = window.AudioWorklet.prototype.addModule;
		window.AudioWorklet.prototype.addModule = function (url, opts) {
			const rec = { url: String(url), ok: null, err: null };
			window.__workletCalls.push(rec);
			return origAdd.call(this, url, opts).then(
				(v) => { rec.ok = true; return v; },
				(e) => { rec.ok = false; rec.err = String(e && e.message || e); throw e; },
			);
		};
	}
	if (window.AudioWorkletNode) {
		window.__workletNodes = 0;
		const OrigNode = window.AudioWorkletNode;
		const WrappedNode = function (...args) {
			window.__workletNodes++;
			return new OrigNode(...args);
		};
		WrappedNode.prototype = OrigNode.prototype;
		window.AudioWorkletNode = WrappedNode;
	}
})()`;

const AUDIO_PROBE = `(() => {
	const ctxs = window.__audioCtxs || [];
	return {
		missing: !!window.__audioCtxsMissing,
		count: ctxs.length,
		states: ctxs.map((c) => c.state),
		sampleRate: ctxs.length ? ctxs[0].sampleRate : 0,
		workletCalls: window.__workletCalls || [],
		workletNodes: window.__workletNodes || 0,
	};
})()`;

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
	await cdp.send('Log.enable');
	await cdp.send('Network.enable');
	await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
	await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: AUDIO_HOOK });

	await cdp.send('Emulation.setDeviceMetricsOverride', {
		width: LANDSCAPE.width, height: LANDSCAPE.height, deviceScaleFactor: DPR, mobile: true,
		screenOrientation: { type: 'landscapePrimary', angle: 90 },
	});
	// 缓存击穿参数要用 & 拼：线上地址本身带 ?sharecode=...，再接 ?p= 会让
	// sharecode 变成 "xxx?p=123"，服务端判为无效直接 403（踩过）。
	const bust = (URL_UNDER_TEST.includes('?') ? '&' : '?') + 'p=' + Date.now();
	await cdp.send('Page.navigate', { url: URL_UNDER_TEST + bust });

	// ---------- 1. 加载 ----------
	let loaded = false;
	for (let i = 0; i < 400; i++) {
		await sleep(300);
		const gone = await cdp.evaluate(`!document.getElementById('status')`);
		if (gone) { loaded = true; break; }
	}
	check('加载完成（#status 已移除）', loaded, loaded ? '' : '120 秒内没走完加载');
	await sleep(1200);

	const menu = await readState(cdp);
	check('引擎回写了 __nsState', menu !== null, menu ? JSON.stringify(menu) : 'null');
	check('停在菜单态', menu && menu.state === S_MENU, 'state=' + (menu && menu.state));

	// ---------- 2. 音频上下文（尚未有用户手势） ----------
	const a0 = await cdp.evaluate(AUDIO_PROBE);
	log(`  加载后 WebAudio：count=${a0.count} states=${JSON.stringify(a0.states)} sr=${a0.sampleRate}`);
	check('浏览器支持并创建了 AudioContext', !a0.missing && a0.count >= 1, 'count=' + a0.count);
	// worklet 是 addModule() 时才拉的，可能早可能晚，不能在这里断言——放到手势之后
	log(`  加载期 worklet：addModule ${a0.workletCalls.length} 次，节点 ${a0.workletNodes} 个`);

	// 没有手势时处于 suspended 是浏览器的正常行为，不是缺陷；这里只记录基线
	log(`  基线（无手势）：${JSON.stringify(a0.states)}`);

	// ---------- 3. 点进游戏（这一步提供用户手势） ----------
	await cdp.shot('web_audio_0_menu');
	let started = null;
	const candidates = [[348, 284]];
	for (const dy of [-14, 0, 14]) for (const dx of [-40, 0, 40]) candidates.push([348 + dx, 284 + dy]);
	for (const [px, py] of candidates) {
		await cdp.click(px, py);
		started = await waitState(cdp, (s) => s.state === S_PLAYING, 2000);
		if (started) {
			log(`  用坐标 (${Math.round(px)}, ${Math.round(py)}) 点进了游戏`);
			break;
		}
	}
	check('点"开始游戏"进入 PLAYING', !!started, started ? JSON.stringify(started) : '所有候选坐标都没点进去');

	// 开局 3 秒左右抓一张：新手的"移动"提示在 1.6 秒出现、停留 3.2 秒，
	// 这张图是用来肉眼确认引导条真的上屏了（headless 测不到"画出来没有"）。
	await sleep(2600);
	await cdp.shot('web_audio_2_early');

	// ---------- 4. 手势之后音频必须 running ----------
	await sleep(1500);
	const a1 = await cdp.evaluate(AUDIO_PROBE);
	log(`  开局后 WebAudio：count=${a1.count} states=${JSON.stringify(a1.states)}`);
	check('用户手势之后 AudioContext 为 running',
		a1.states.length > 0 && a1.states.every((s) => s === 'running'),
		JSON.stringify(a1.states));

		const a2 = await cdp.evaluate(AUDIO_PROBE);
	const calls = a2.workletCalls || [];
	log(`  addModule 调用：${calls.map((c) => `${c.url.split('/').pop()} ok=${c.ok}${c.err ? ' err=' + c.err : ''}`).join(', ') || '（无）'}`);
	check('音频 worklet 模块已 addModule 且成功',
		calls.length >= 1 && calls.every((c) => c.ok !== false),
		calls.length ? calls.map((c) => `${c.url.split('/').pop()} ok=${c.ok}`).join(', ') : '没有 addModule 调用');
	check('AudioContext 采样率正常', a2.sampleRate === 44100 || a2.sampleRate === 48000,
		a2.sampleRate + 'Hz');

	// ---------- 5. 跑 12 秒战斗，看有没有静默的脚本错误 ----------
	// 12 秒里必然会升一次级（state=2 选卡态）。那不是"被打断"，是正常推进，
	// 所以这里只要求"没退出到菜单、没死"，并且顺手点一张卡让它继续跑。
	await sleep(12000);
	let playing = await readState(cdp);
	if (playing && playing.state === 2) {
		log('  升级选卡中（state=2），点第一张卡继续');
		await cdp.click(300, 200);
		await sleep(900);
		playing = await readState(cdp);
	}
	check('12 秒后仍在局内（没死、没回菜单）',
		playing && (playing.state === S_PLAYING || playing.state === 2),
		playing ? JSON.stringify(playing) : 'null');
	check('局内计时真的在推进', playing && playing.elapsed > 3.0,
		'elapsed=' + (playing && playing.elapsed));
	await cdp.shot('web_audio_1_playing');

	// 音效是 GDScript 侧的，浏览器这边只能间接看：如果音频子系统报错，
	// 会打在 console.error 里。所以"零报错"就是这一项最好的证据。
	if (cdp.badUrls && cdp.badUrls.length) {
		log('  失败请求：');
		for (const u of cdp.badUrls.slice(0, 8)) log('    ' + u);
	}
	// 两类失败要分开看：网络 4xx 由 badUrls 判定（它有完整 URL），
	// 而 console 里那条 "Failed to load resource ... 403" 是浏览器自己请求
	// favicon.ico 产生的，页面上根本没这个词，按名字过滤不掉，只能按"裸网络文案"排除。
	const realErrors = cdp.errors.filter((e) =>
		!/favicon|Download the React|DevTools/i.test(e) &&
		!/^log: Failed to load resource/.test(e));
	check('无 4xx/5xx 资源请求', !(cdp.badUrls && cdp.badUrls.length),
		(cdp.badUrls || []).join(' | '));
	check('全程无 JS 异常 / console.error', realErrors.length === 0,
		realErrors.length ? realErrors.slice(0, 5).join(' | ') : '');

	log('');
	log(`=== ${fails.length === 0 ? '全部通过' : '存在问题'}（${lines.filter((l) => l.startsWith('[OK]')).length} 通过 / ${fails.length} 失败）===`);
	writeFileSync(`${OUT_DIR}/web_audio_${OUT_TAG}.txt`, lines.join('\n'), 'utf-8');
	ws.close();
	process.exit(fails.length === 0 ? 0 : 1);
}

main().catch((e) => {
	log('FATAL ' + e.message);
	writeFileSync(`${OUT_DIR}/web_audio_${OUT_TAG}.txt`, lines.join('\n'), 'utf-8');
	process.exit(1);
});
