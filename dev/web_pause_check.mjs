// 外部打断暂停的端到端验收（原生 CDP，无第三方依赖）。
//
// 用法：
//   1) python -m http.server 8123 --directory build/web
//   2) msedge --headless=new --remote-debugging-port=9222 about:blank
//   3) node dev/web_pause_check.mjs
//
// 验证的是"shell → 引擎"这条链真的通了：
//   方向 / 页面可见性变化 → window.__nsPause(reason, on) → GDScript 回调 → get_tree().paused
// 引擎把结果写回 window.__nsState（JSON），这里读它做断言——
// 不靠肉眼看截图判断"是不是真的停了"。
//
// 切后台用的是"劫持 document.hidden + 派发真实的 visibilitychange"，
// 不是 Page.setWebLifecycleState('frozen')：后者会把页面脚本执行一起冻住，
// 冻住之后 CDP 的 evaluate 也执行不了，等于没法验证冻住之后的状态。
// 劫持只改了这一个属性，shell 的监听器与传值路径都是真的走了一遍。
//
// 结果写 .workbuddy/web_pause.txt，截图写 .workbuddy/web_pause_*.png。

import { writeFileSync, mkdirSync } from 'node:fs';

const CDP = 'http://127.0.0.1:9222';
const URL_UNDER_TEST = 'http://127.0.0.1:8123/index.html';
const OUT_DIR = '.workbuddy';

const PORTRAIT = { width: 390, height: 844 };
const LANDSCAPE = { width: 844, height: 390 };
const DPR = 2;

// Godot 的 State 枚举
const S_MENU = 0;
const S_PLAYING = 1;
const S_LEVEL_UP = 2;
// 剧情屏（State.STORY）。开局和每次穿门都会出现，按 ESC 跳过。
const S_STORY = 7;

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
	/** 在视口坐标 (x,y) 上点击一次。Godot 的 canvas 监听的是 DOM 鼠标事件。 */
	async click(x, y) {
		const base = { x, y, button: 'left', clickCount: 1 };
		await this.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...base, button: 'none' });
		await this.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base });
		await sleep(60);
		await this.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base });
	}
	/**
	 * 按一次键。选卡面板吃的是 Godot 的键盘输入，不是 DOM 点击——
	 * 用键而不是点坐标：卡片位置随视口和缩放变，坐标写死过两次，换分辨率就点空。
	 */
	async press(key, code, keyCode) {
		const base = { key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode };
		await this.send('Input.dispatchKeyEvent', { type: 'keyDown', ...base, text: key });
		await sleep(50);
		await this.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base });
	}
}

/** 读引擎回写的状态。引擎没起来时返回 null。 */
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
			// 升级选卡（state=2）自己也会把树暂停，和"竖屏/后台"是两回事。
			// 以前这条脚本能过，是因为第一张卡要很久才来；经验翻倍后 14 秒就到 Lv.2，
			// 后面的"横屏恢复"全被这张卡挡住，报出来的失败是假的。
			// 处理方式与台架 bot 一致：看到选卡就按 1 选第一张，继续测暂停。
			// 顺序不能反：先判 predicate 再按键——等"已暂停"时按键是白按，
			// 本来该立刻通过的断言会被拖到超时。
			if (s && s.state === S_LEVEL_UP) {
				await cdp.press('1', 'Digit1', 49);
				await sleep(250);
				continue;
			}
			// 剧情屏（state=7）。同样的道理：它也会冻结整棵树，
			// 而且不处理就会把"开局 2 秒内进 PLAYING"这条断言拖到超时。
			// 按 ESC = 跳过整幕（和右上角那颗按钮等价）。
			if (s && s.state === S_STORY) {
				await cdp.press('Escape', 'Escape', 27);
				await sleep(250);
				continue;
			}
		} catch (e) { /* 导航中上下文会被替换 */ }
		await sleep(150);
	}
	// 超时必须返回 null：返回旧值会让"有没有点进去"这种断言永远通过
	return null;
}

async function setOrientation(cdp, size, type, angle) {
	await cdp.send('Emulation.setDeviceMetricsOverride', {
		width: size.width, height: size.height, deviceScaleFactor: DPR, mobile: true,
		screenOrientation: { type, angle },
	});
	await sleep(600);
}

/** 模拟切后台：劫持 document.hidden（定义在原型上，实例自有属性可遮蔽），再派发真实事件。 */
async function setHidden(cdp, hidden) {
	const got = await cdp.evaluate(`(() => {
		if (!window.__hiddenHooked) {
			window.__hiddenHooked = true;
			window.__hiddenValue = document.hidden;
			Object.defineProperty(document, 'hidden', {
				configurable: true,
				get: function () { return window.__hiddenValue; },
			});
		}
		window.__hiddenValue = ${hidden ? 'true' : 'false'};
		document.dispatchEvent(new Event('visibilitychange'));
		return document.hidden;
	})()`);
	await sleep(400);
	return got;
}

const COPY_PROBE = `(() => {
	const rot = document.getElementById('rotate');
	const head = rot ? rot.querySelector('.headline') : null;
	const sub = rot ? rot.querySelector('.subline') : null;
	const tip = document.getElementById('rotate-percent');
	const cs = rot ? getComputedStyle(rot) : null;
	return {
		display: cs ? cs.display : 'absent',
		headline: head ? head.textContent : null,
		sub: sub ? sub.innerText.replace(/\\n/g, ' / ') : null,
		tip: tip ? tip.textContent : null,
		nsPauseType: typeof window.__nsPause,
		hasResync: typeof window.__nsResync,
	};})()`;

function reasonsOf(st) {
	if (!st || !Array.isArray(st.reasons)) return [];
	return st.reasons;
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
	await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });

	// ---------- 1. 横屏加载 ----------
	await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);
	await cdp.send('Page.navigate', { url: URL_UNDER_TEST + '?p=' + Date.now() });

	let loaded = false;
	for (let i = 0; i < 400; i++) {
		await sleep(300);
		const gone = await cdp.evaluate(`!document.getElementById('status')`);
		if (gone) { loaded = true; break; }
	}
	check('加载完成进菜单', loaded, loaded ? '' : '120 秒内没走完加载');
	await sleep(1200);

	// ---------- 2. 桥接是否建立 ----------
	const copy0 = await cdp.evaluate(COPY_PROBE);
	check('shell 注册了 __nsResync', copy0.hasResync === 'function', 'typeof=' + copy0.hasResync);
	check('引擎注册了 __nsPause', copy0.nsPauseType === 'function', 'typeof=' + copy0.nsPauseType);

	const menu = await waitState(cdp, () => true, 5000);
	check('引擎回写了 __nsState', menu !== null, menu ? JSON.stringify(menu) : 'null');
	check('菜单态 state=MENU', menu && menu.state === S_MENU, 'state=' + (menu && menu.state));
	check('菜单态本来就是暂停', menu && menu.paused === true, 'paused=' + (menu && menu.paused));

	// ---------- 3. 开局（点击"开始游戏"） ----------
	// 坐标按截图实测标定：16:9 的画面在 844x390 视口里左右有黑边，
	// "开始游戏"按钮中心落在视口 (348, 284) 附近。给一个 3x3 的网格兜底。
	await cdp.shot('web_pause_0_menu');

	let started = null;
	const candidates = [[348, 284]];
	for (const dy of [-14, 0, 14]) {
		for (const dx of [-40, 0, 40]) {
			candidates.push([348 + dx, 284 + dy]);
		}
	}
	for (const [px, py] of candidates) {
		await cdp.click(px, py);
		started = await waitState(cdp, (s) => s.state === S_PLAYING, 2000);
		if (started) {
			log(`  用坐标 (${Math.round(px)}, ${Math.round(py)}) 点进了游戏`);
			break;
		}
	}
	check('点"开始游戏"进入 PLAYING', !!started, started ? JSON.stringify(started) : '所有候选坐标都没点进去');

	if (!started) {
		log('');
		log(`=== ${'存在问题'}（失败 ${fails.length} 项）===`);
		writeFileSync(`${OUT_DIR}/web_pause.txt`, lines.join('\n'), 'utf-8');
		ws.close();
		return;
	}
	check('开局后不暂停', started.paused === false, 'paused=' + started.paused);

	// ---------- 4. 竖屏 → 暂停 ----------
	await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
	let st = await waitState(cdp, (s) => s.paused === true, 4000);
	check('竖屏后引擎暂停', st && st.paused === true, st ? JSON.stringify(st) : 'null');
	check('竖屏不改 state（仍是 PLAYING）', st && st.state === S_PLAYING, 'state=' + (st && st.state));
	check('竖屏记入 reasons', reasonsOf(st).includes('portrait'), 'reasons=' + JSON.stringify(reasonsOf(st)));

	const copyP = await cdp.evaluate(COPY_PROBE);
	check('竖屏：提示层可见', copyP.display === 'flex', 'display=' + copyP.display);
	check('竖屏：文案是"已暂停"', copyP.headline === '已暂停', 'headline=' + copyP.headline);
	check('竖屏：副标题说明会自动暂停', (copyP.sub || '').indexOf('暂停') >= 0, 'sub=' + copyP.sub);
	await cdp.shot('web_pause_1_portrait');

	// ---------- 5. 横屏 → 恢复 ----------
	await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);
	st = await waitState(cdp, (s) => s.paused === false, 4000);
	check('横屏后恢复运行', st && st.paused === false, st ? JSON.stringify(st) : 'null');
	check('横屏后仍是 PLAYING', st && st.state === S_PLAYING, 'state=' + (st && st.state));
	check('横屏后 reasons 清空', reasonsOf(st).length === 0, 'reasons=' + JSON.stringify(reasonsOf(st)));
	const copyL = await cdp.evaluate(COPY_PROBE);
	check('横屏：提示层隐藏', copyL.display === 'none', 'display=' + copyL.display);

	// ---------- 6. 来回 3 次：每次都必须一停一恢复 ----------
	for (let round = 1; round <= 3; round++) {
		await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
		const sp = await waitState(cdp, (s) => s.paused === true, 4000);
		check(`第 ${round} 轮·竖屏暂停`, sp && sp.paused === true, sp ? 'paused=' + sp.paused : 'null');

		await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);
		const sl = await waitState(cdp, (s) => s.paused === false, 4000);
		check(`第 ${round} 轮·横屏恢复`, sl && sl.paused === false, sl ? 'paused=' + sl.paused : 'null');
		check(`第 ${round} 轮·仍在同一局`, sl && sl.state === S_PLAYING, 'state=' + (sl && sl.state));
	}

	// ---------- 7. 切后台 → 暂停 ----------
	await setHidden(cdp, true);
	st = await waitState(cdp, (s) => s.paused === true, 4000);
	check('切后台后引擎暂停', st && st.paused === true, st ? JSON.stringify(st) : 'null');
	check('切后台记入 reasons', reasonsOf(st).includes('hidden'), 'reasons=' + JSON.stringify(reasonsOf(st)));
	check('切后台不改 state', st && st.state === S_PLAYING, 'state=' + (st && st.state));

	await setHidden(cdp, false);
	st = await waitState(cdp, (s) => s.paused === false, 4000);
	check('回前台后恢复', st && st.paused === false, st ? JSON.stringify(st) : 'null');

	// ---------- 8. 竖屏 + 后台同时成立：解除一个不许恢复 ----------
	await setOrientation(cdp, PORTRAIT, 'portraitPrimary', 0);
	await waitState(cdp, (s) => s.paused === true, 3000);
	await setHidden(cdp, true);
	st = await waitState(cdp, (s) => reasonsOf(s).length === 2, 4000);
	check('两个原因都被记下', reasonsOf(st).length === 2, 'reasons=' + JSON.stringify(reasonsOf(st)));

	// 转横屏（手机还揣在兜里 / 还停在别的应用）
	await setOrientation(cdp, LANDSCAPE, 'landscapePrimary', 90);
	await sleep(700);
	st = await readState(cdp);
	check('只解除竖屏仍然暂停（还在后台）', st && st.paused === true,
		st ? 'paused=' + st.paused + ' reasons=' + JSON.stringify(reasonsOf(st)) : 'null');

	await setHidden(cdp, false);
	st = await waitState(cdp, (s) => s.paused === false, 4000);
	check('两个都解除才恢复', st && st.paused === false, st ? 'paused=' + st.paused : 'null');

	// ---------- 9. 暂停期间局内时间不许走 ----------
	await setHidden(cdp, true);
	const t1 = await readState(cdp);
	await sleep(1500);
	const t2 = await readState(cdp);
	check('后台期间局内时间不推进',
		t1 && t2 && Math.abs(t2.elapsed - t1.elapsed) < 0.25,
		`elapsed ${t1 && t1.elapsed} → ${t2 && t2.elapsed}`);

	await setHidden(cdp, false);
	await sleep(900);
	const t3 = await readState(cdp);
	check('回前台后局内时间恢复推进',
		t3 && t2 && t3.elapsed > t2.elapsed + 0.4,
		`elapsed ${t2 && t2.elapsed} → ${t3 && t3.elapsed}`);

	// ---------- 10. 桌面竖窗口不许误触发 ----------
	// 判定用的是 matchMedia 而不是"高比宽大"，就是为了这一条：
	// 桌面把浏览器窗口拖成竖的（宽度 > 820、指针是 fine）画面照样能玩，
	// 弹"请把手机横过来"并暂停只会让人以为游戏坏了。
	await cdp.send('Emulation.setDeviceMetricsOverride', {
		width: 1280, height: 900, deviceScaleFactor: 1, mobile: false,
		screenOrientation: { type: 'portraitPrimary', angle: 0 },
	});
	await sleep(900);
	// 同样要放过一次可能的升级选卡：那一刻 paused=true 是卡片挡的，不是竖屏挡的
	const desk = (await waitState(cdp, (s) => s.paused === false, 3000)) || (await readState(cdp));
	const deskCopy = await cdp.evaluate(COPY_PROBE);
	check('桌面竖窗口：不暂停', desk && desk.paused === false, desk ? 'paused=' + desk.paused : 'null');
	check('桌面竖窗口：不显示横屏提示', deskCopy.display === 'none', 'display=' + deskCopy.display);

	log('');
	log(`=== ${fails.length === 0 ? '全部通过' : '存在问题'}（失败 ${fails.length} 项）===`);
	if (fails.length) fails.forEach((f) => log('  FAIL ' + f));

	writeFileSync(`${OUT_DIR}/web_pause.txt`, lines.join('\n'), 'utf-8');
	ws.close();
}

await main();
