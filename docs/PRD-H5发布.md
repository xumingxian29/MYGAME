# PRD：游戏 H5 网页版发布

| 项 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 日期 | 2026-11-24 |
| 项目 | MY GAME（Godot 4.7.2 / 纯 GDScript） |
| 交付形态 | 浏览器可打开的静态站点（`index.html` + WebAssembly） |
| 关联决策 | 方案 A：保留 Godot 工程，导出 Web，不重写逻辑 |

---

## 1. 背景与问题

游戏目前只能在装了 Godot 引擎的机器上通过命令行运行，别人拿到 GitHub 仓库后无法直接玩，也没法在手机上打开。需要一个"点开链接就能玩"的版本。

选择 Godot 官方 Web 导出的理由：项目 100% 由代码构建场景，所有图形都是 `_draw()` 画的圆与多边形，**没有任何外部美术素材**。因此导出包只包含引擎本体，不携带图片资源，是 Godot 工程里最轻的一种情况。

### 当前阻碍导出的硬条件（已实测确认）

| # | 问题 | 现状 | 结论 |
|---|---|---|---|
| A | 渲染后端 | `config/features` 写死 `Forward Plus` | Web 不支持 Vulkan/Forward+，必须先切 GL Compatibility |
| B | 字体 | `UiKit.font()` 用 `SystemFont` + `["Microsoft YaHei", "SimHei", "Segoe UI"]` | **Web 平台无系统字体访问能力**，SystemFont 会退化到引擎内置 OpenSans，中文字全部变方块 |
| C | 视口尺寸 | 未显式设置 | 需固定基准分辨率 + 自适应策略，否则手机上会被裁切 |
| D | 输入 | 仅键盘（WASD + 空格） | 桌面浏览器可用；手机端已由虚拟摇杆补齐（§9） |
| E | 导出模板 | 未安装 | 必须下载 Web 导出模板，否则导出按钮不可用 |
| F | 物理引擎声明 | `3d/physics_engine="Jolt Physics"` | Web 模板不含 Jolt，2D 游戏用不到，应移除以避免启动告警 |
| G | 存档持久化 | `user://records.json` | Web 下映射到浏览器 IndexedDB，需确认刷新后不丢档 |

---

## 2. 目标与非目标

### 目标

1. 在桌面浏览器（Chrome / Edge，支持 WebGL2）打开链接即可游玩，操作与桌面版一致。
2. 手机横屏打开时用虚拟摇杆 + 技能键即可完整游玩（不依赖任何键盘）。
2. 中文菜单、HUD、昵称输入全部正常显示，无方块字。
3. 历史最高分在关闭标签页、重开浏览器后仍然保留。
4. 首屏从打开到可操作 ≤ 10 秒（本地 / 常规宽带）。
5. 产物为纯静态文件，可部署到任意静态托管（GitHub Pages、Vercel、对象存储）。

### 非目标（本期不做）

- 微信小游戏（Godot 无该导出目标，且主包 4MB 限制无法满足）
- 多人联机、账号系统、排行榜服务器
- 音效 / 音乐（项目当前无音频系统）
- 替换 `_draw()` 占位图形为真实美术
- 重写玩法逻辑

---

## 3. 目标用户与场景

| 用户 | 场景 | 关键诉求 |
|---|---|---|
| 项目作者 | 把链接发给朋友试玩 | 对方不用装任何东西 |
| 朋友 / 路人 | 桌面浏览器点开就玩 | 加载不要等太久，操作要一眼看懂 |
| 手机用户（P1） | 微信内置浏览器或 Safari 打开 | 需要虚拟摇杆才能玩 |

---

## 4. 需求明细

### R1 · 渲染后端切换（P0）

- `project.godot` 中 `config/features` 由 `("4.7", "Forward Plus")` 改为 `("4.7", "GL Compatibility")`。
- 显式声明 `rendering/renderer/rendering_method="gl_compatibility"` 与 `rendering_method.mobile="gl_compatibility"`。
- **回归风险**：`damage_vignette.gdshader`（低血红边）需在 GL Compatibility 下重新验证；`_draw()` 全部为 2D 图元，不受影响。
- 桌面端本地运行效果不得改变（`--headless` 与开窗各跑一遍零报错）。

### R2 · 中文字体内嵌（P0，核心）

- **放弃 `SystemFont`**，改为内嵌字体文件 + `FontFile`。
- 字体选型：Noto Sans SC（OFL 协议，可商用可分发）。
- **必须做子集化**，否则完整字库约 10MB，会明显拖慢加载：
  - 覆盖范围 = GB2312 一级+二级汉字（6763 字）+ ASCII + 全角标点 + 游戏内固定文案全部字符。
  - 目标体积 ≤ 3MB（gzip 后 ≤ 1.5MB）。
- 昵称由玩家输入，**生僻字可能显示为方块**——这是子集化的已知取舍，在 PRD 中记录为可接受。若后续需要全覆盖，改用完整字库并接受体积代价。
- 实现方式：`UiKit.font()` 返回 `FontFile`（`load("res://assets/fonts/NotoSansSC-subset.otf")`），调用方签名不变（`Label` / `draw_string` 都接受 `Font`）。
- 兜底：字体加载失败时退回 `ThemeDB.fallback_font`，不得因字体缺失导致脚本报错。

### R3 · 视口与响应式（P0）

- 基准分辨率：`1280 × 720`（16:9），写入 `display/window/size/viewport_width/height`。
- `window/stretch/mode="canvas_items"`、`aspect="expand"`（已具备，保留）。
- 浏览器窗口任意比例下：HUD 不裁切、不重叠；超宽屏时以 16:9 为安全区，边缘留空。
- 竖屏（手机）显示"请横屏游玩"提示层，横屏后自动消失（P1 一并做）。

### R4 · 移动端触屏输入（P1 → 已完成，实现见 §9）

- 左下角虚拟摇杆：触摸拖动 → 映射到 `move_left/right/up/down` 四个动作（复用现有 InputMap，不改玩家移动代码）。
- 右下角技能按钮：满蓝时高亮，触摸触发 `cast_skill`。
- 摇杆用 `Control` + `_gui_input` 实现，仅 `OS.has_feature("web")` 且检测到触摸设备时显示；桌面浏览器不出现。
- 触摸区不得遮挡 HUD 与升级三选一卡片。

### R5 · 加载体验（P0）

- 自定义 HTML 加载页：游戏标题 + 进度条 + "首次加载约需 X 秒"提示，替换 Godot 默认黑屏。
- 引擎启动后隐藏加载页，禁止出现白屏闪烁。
- 加载失败（WebGL2 不可用）时给出明确中文提示，而不是静默黑屏。

### R6 · 存档持久化（P0）

- Web 下 `user://` 落在 IndexedDB。需实测：写入最高分 → 刷新页面 → 记录仍在。
- 若发现丢失，在 `ScoreBoard.save()` 后显式调用同步点（Godot 4 Web 的 `OS` 无直接 flush API，需靠引擎周期性同步；必要时改为写完后 `await` 一帧再提示）。
- 不做跨设备同步。

### R7 · 导出与部署（P0 → 已完成，公网部署见 §10）

- 安装 Web 导出模板（约 1GB，含各平台；仅用 Web 部分）。
- 新增 `export_presets.cfg`，预设名 `Web`，包含：
  - 导出路径 `build/web/index.html`
  - `variant/extensions_support=false`（不需要扩展）
  - `vram_texture_compression/for_desktop=false`
  - 线程支持关闭（单线程，避免 COOP/COEP 跨源隔离要求，方便任意静态托管）
- 产物目录 `build/` 加入 `.gitignore`（构建物不入库）。
- 提供 `serve.py` 或一行命令启动本地服务器（**不能直接双击 index.html**，浏览器禁止 `file://` 下加载 wasm）。

### R8 · 工程清理（P2）

- 移除 `3d/physics_engine="Jolt Physics"`。
- `rendering_device/driver.windows="d3d12"` 仅影响 Windows 本地，Web 忽略，可保留。
- 中文文件名（`MY主场景.tscn`）在 pck 内为 UTF-8，Web 导出无影响，暂不改名。

---

## 5. 验收标准

| # | 验收项 | 判定方式 | 通过标准 |
|---|---|---|---|
| 1 | 桌面浏览器可玩 | Chrome 打开本地服务 | 选职业 → 开始 → 能移动、能攻击、能升级选卡、能死亡重开 |
| 2 | 无方块字 | 截图检查菜单 / HUD / 结算面板 / 昵称 | 中文全部正常渲染，0 处豆腐块 |
| 3 | 控制台零报错 | 浏览器 DevTools Console | 无 `SCRIPT ERROR`，无 shader 编译失败 |
| 4 | 存档持久化 | 打一局 → 刷新 → 看战绩榜 | 最高分仍在 |
| 5 | 加载耗时 | 冷缓存首次打开 | ≤ 10 秒进入可操作状态 |
| 6 | 低血红边 | 残血截图 | 四边红色脉动正常显示（GL Compatibility 下 shader 生效） |
| 7 | 自适应 | 窗口拉成 21:9 / 4:3 各截一张 | HUD 不裁切、不重叠 |
| 8 | 桌面版无回归 | 本地 `--headless` 900 帧 + 开窗 600 帧 | 零报错，玩法与改前一致 |

---

## 6. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 字体压缩后仍偏大 | 首屏慢 | 严格子集化；字体单独走 CDN 缓存头 |
| GL Compatibility 下 shader 表现差异 | 红边失效或过曝 | R1 落地后立即截图验证，必要时降级为纯 ColorRect 渐变 |
| 导出模板下载失败（网络受限） | 无法导出 | 手动从 GitHub Releases 下载 `.tpz` 放入 `%APPDATA%\Godot\export_templates\4.7.2.stable\` |
| 手机性能不足（WebGL2 + 大量 `_draw`） | 掉帧 | 已知：同屏敌人预算上限 12+ 秒数/3，实测后视情况下调 |
| 微信内置浏览器内核差异 | 手机上打不开 | 明确提示"请用系统浏览器打开"；本期不保证微信内可玩 |

---

## 7. 实施顺序

| 阶段 | 内容 | 产出 |
|---|---|---|
| S1 | R1 渲染器 + R8 清理 + 本地回归 | 本地桌面版跑通，无报错 |
| S2 | R2 字体子集化与接入 | 本地中文正常，体积达标 |
| S3 | R3 视口 + R5 加载页 + R7 导出配置 | 导出成功，本地服务器可打开 |
| S4 | 浏览器内实测与验收表逐项打勾 | 验收报告 |
| S5 | R4 虚拟摇杆 + 竖屏提示 | 手机可玩（已落地，见 §9） |

S1–S4 为"桌面浏览器可玩"的最小闭环；S5（手机可玩）已于同日完成。

---

## 8. 实施记录与验收结果（2026-11-24）

### 落地清单

| 需求 | 状态 | 实际做法 |
|---|---|---|
| R1 渲染后端 | 完成 | `config/features` → `GL Compatibility`，并显式写 `rendering_method` 与 `rendering_method.mobile` |
| R2 中文字体 | 完成 | Noto Sans SC 子集（ASCII + GB2312 全表 + 项目文案共 6957 字），**7.95MB → 1.46MB**；`UiKit.font()` 改返回 `FontFile`，缺失时回退 `ThemeDB.fallback_font` |
| R3 视口自适应 | 完成 | 基准 1280×720 + `canvas_items` / `expand`；竖屏窄屏显示"请横屏游玩" |
| R4 虚拟摇杆 | 完成 | 新增 `scripts/ui/touch_controls.gd`：左下浮动摇杆 + 右下技能键，仅触屏设备出现；手机基准分辨率降到 960×540 |
| R5 加载页 | 完成 | `web/shell.html` 自定义 shell：标题 + 进度条 + 百分比 + 中文失败提示 + WebGL 检测 |
| R6 存档持久化 | 完成 | 实测写入 IndexedDB `/userfs/godot/app_userdata/MY GAME/records.json`，刷新后读回 |
| R7 导出部署 | 完成 | `export_presets.cfg`（nothreads，无需 COOP/COEP）+ `serve.py`（带 gzip） |
| R8 工程清理 | 完成 | 移除 `3d/physics_engine="Jolt Physics"` 与 d3d12 驱动声明 |

### 验收表实测

| # | 验收项 | 结果 | 证据 |
|---|---|---|---|
| 1 | 桌面浏览器可玩 | 通过 | 模拟点击开始 → 击杀 3 / Lv.2 / 升级三选一正常 |
| 2 | 无方块字 | 通过 | 菜单、HUD、结算、加载页中文全部正常 |
| 3 | 控制台零报错 | 通过 | 仅 3 条引擎启动日志，无 SCRIPT ERROR / exception |
| 4 | 存档持久化 | 通过 | 打一局死亡 → 刷新页面 → 菜单仍显示「玩家 最高 4939 1局」 |
| 5 | 加载耗时 | 通过 | 本地未限速约 3~5 秒；wasm gzip 后 10.1MB（原 38.6MB） |
| 6 | 低血红边 | 通过 | GL Compatibility 下截图像素级确认四边红色脉动 |
| 7 | 自适应 | 通过 | 1600×680 超宽 HUD 不裁切；760×900 竖屏正确提示横屏 |
| 8 | 桌面版无回归 | 通过 | 无头 900 帧 + 开窗截图零报错，玩法与改前一致 |

### 产品参数（实测）

| 项 | 值 |
|---|---|
| 产物总大小 | 约 40MB（未压缩）/ 约 12MB（gzip 传输） |
| `index.wasm` | 38.6MB → gzip 10.1MB |
| `index.pck` | 1.4MB |
| 引擎版本 | Godot 4.7.2.stable，Emscripten 4.0.20，单线程，无 GDExtension |
| 渲染后端 | OpenGL ES 3.0 (WebGL 2.0)，Compatibility |
| 存档位置 | 浏览器 IndexedDB `/userfs` |

### 已知限制

1. **打字仍需系统输入法**：昵称输入框是原生 `LineEdit`，手机浏览器下不一定弹出软键盘（Godot Web 的可选框内键盘还是实验特性，开启后会抢键盘事件，影响 WASD，故未启用）。规避方式：默认昵称「玩家」直接可开局，或点战绩榜里的历史记录开局。
2. **昵称生僻字可能显示方块**：字体做了子集化，只覆盖 GB2312 常用字。
3. **首屏受网速影响**：10MB 传输在 4G 下约 5~15 秒。
4. **不支持 `file://` 直接打开**：必须经 HTTP（`python serve.py`）。
5. **低端机可能掉帧**：手机端可见世界范围比桌面小（960 基准反而放大了物体），同屏敌人数量由存活时间决定，未针对移动 GPU 单独限流。

### 复现命令

```bash
# 导出（先建目录，Godot 不会自动创建）
mkdir -p build/web
godot --headless --path . --export-release "Web" build/web/index.html
# 预览
python serve.py 8080     # 打开 http://127.0.0.1:8080/
```

导出前必须先建好 `build/web` 目录，Godot 不会自动创建，否则报"目标文件夹不存在"。

---

## 9. R4 触屏操作（2026-11-24 完成）

### 设计取舍

| 决策 | 做法 | 为什么不那么做 |
|---|---|---|
| 摇杆怎么驱动移动 | `Input.action_press()` 写进 `move_left/right/up/down`，带 0~1 强度 | 直接改 `Player.global_position` 会和键盘抢状态，还要在 Player 里加"触屏模式"分支；走 InputMap 后玩家代码一行未动，模拟量天生支持（推一半走半速） |
| 摇杆位置 | **浮动**：按在圈里用画的底盘，按在别处则底盘挪到指尖下 | 固定底盘在 5 寸屏上要"先找再按"，横屏时拇指落点每次都不一样 |
| 触摸事件走哪 | `_input` 手动做区域命中，不用 `_gui_input` | 摇杆感应区覆盖左半屏，做成 Control 会把这块区域变成"吃掉点击"的控件，还得在暂停时收拾 |
| 桌面怎么调试 | `godot --path . -- --touch`：强制开触屏 + 鼠标当单指 | 不开真机也能拖摇杆验收 |
| 手机分辨率 | 触屏设备把逻辑分辨率从 1280×720 降到 960×540 | 844×390 的机器上 16px 字号只剩 8 个 CSS 像素，血条数字看不清 |
| 结算页操作 | 触屏模式把「R 再来一局 / P 换人」换成两个大按钮 | 手机上既没有 R 也没有 P，不改就是死路 |
| 技能键 | 右下角圆形按钮，蓝量画成圆环，满蓝变金 + 呼吸光环 | 手机上没有空格键，HUD 的"空格 · 技能名"在触屏下改成"点按 · 技能名" |

### 关键实现细节

- **多指**：摇杆与技能键各记一个手指 id，左手推着走、右手点技能互不打断（实测验证）。
- **暂停收起**：升级选卡 / 结算 / 菜单时整层隐藏并强制松开所有移动动作，否则暂停时角色会带着残留输入继续滑。
- **坐标系**：尺寸全部按"视口高度 / 540"缩放，画布坐标由引擎的 stretch 变换统一处理，桌面 720 与手机 540 两套基准都不用改常量。
- **顺手修的旧 bug**：升级卡的图标底板是 `PanelContainer`（默认 `MOUSE_FILTER_STOP`），点卡片图标那一块原来什么都不发生——桌面端也一样。已改为 `IGNORE`，整张卡都能点。

### 验收记录（实测）

| 项 | 方法 | 结果 |
|---|---|---|
| 逻辑自检 32 项 | `dev/touch_probe.gd` 注入真实触摸事件（无头模式） | 32/32 通过：上推/半推位移、松手归零、浮动底盘、技能空蓝与满蓝、双指并行、暂停收起、结算按钮文案与尺寸、按钮重开 |
| 手机横屏实机流程 | Edge 模拟 844×390 + `maxTouchPoints=5`，真实触摸事件 | 选职业 → 开局 → 摇杆拖动（手柄偏离圆心、网格随即滚动）→ 升级面板点卡片 → 死亡结算面板两个按钮正常 |
| 触屏文案 | 同上截图 | HUD 满蓝显示「点按 · 旋风斩」；菜单提示改为「左侧拖动移动 · 自动攻击 · 右下角放技能 · 升级点卡片」；升级面板「点按卡片选择」 |
| 桌面无回归 | 1280×720 无触摸模拟 | 无摇杆/技能键，HUD 仍显示「空格 · 技能名」，结算仍显示「R / P」 |
| 竖屏 | 390×844 | 自定义加载页正确覆盖「请横屏游玩」 |
| 控制台 | 三套环境 | 0 条 error / exception |
| 桌面版无头回归 | 900 帧 | 零报错 |

### 自检工具（已随仓库保留，导出时被 `dev/*` 排除，不进 pck）

```bash
# 触屏逻辑自检（32 项断言，无头即可跑）
godot --headless --path . dev/touch_probe.tscn -- --touch
# 关键界面截图（开窗跑，输出到 build/probe_*.png）
godot --path . dev/touch_probe.tscn -- --touch --shots
# 浏览器内验收（需先 python serve.py 8080）
python dev/mobile_check.py        # 手机横屏 + 触摸模拟
MV_W=1280 MV_H=720 MV_MOBILE=0 MV_TOUCH=0 MV_PREFIX=desktop python dev/mobile_check.py
```


---

## 10. 公网部署到 GitHub Pages（2026-11-24 完成）

**在线地址：<https://xumingxian29.github.io/MYGAME/>**

### 10.1 这条路为什么能走通

三件事凑齐才成立，少一件都要换方案：

| 前提 | 本项目的情况 |
|---|---|
| 不需要 COOP/COEP 响应头 | 用 **nothreads** 模板导出，不依赖 `SharedArrayBuffer`。GitHub Pages 无法自定义响应头，这一条是决定性的 |
| 资源路径必须是相对的 | 加载页里只有 `index.js` / `index.wasm` / `index.pck` 三个相对引用，没有以 `/` 开头的绝对路径，所以放在 `/MYGAME/` 子目录下能正确解析 |
| wasm 要能被流式编译 | GitHub Pages 对 `.wasm` 返回 `application/wasm`（实测确认），`WebAssembly.instantiateStreaming` 直接可用 |

### 10.2 发布方式：`deploy_pages.sh`

```bash
./deploy_pages.sh              # 导出 + 推送
./deploy_pages.sh --no-export  # 只重推现有 build/web
```

脚本做四件事，每一步都有个明确的"为什么"：

1. **白名单挑文件**，不用 `cp build/web/*`。产物目录里还有 `.import`（编辑器生成的资源元数据）和 `.gzcache`（`serve.py` 的 gzip 缓存），传上去纯属噪音。
2. **写一个空 `.nojekyll`**。否则 GitHub 会先拿 Jekyll 处理一遍静态站点，纯属浪费，还可能吞掉下划线开头的文件。
3. **在 `build/pages` 里新建一个临时仓库**，只提交这一次的内容。
4. **`--force` 推送到 `gh-pages`**。

第 3、4 步是刻意的：wasm 单文件 39.5MB，如果每次发布都往同一分支追加提交，十几次之后仓库就是几百 MB，克隆会变得很慢。强推单提交后，`gh-pages` 分支永远只有一个 commit，仓库体积只跟当前构建有关。

仓库 **Settings → Pages** 的 Source 已经是 `gh-pages / (root)`（通过 API 读到 `source.branch = gh-pages`, `build_type = legacy`），所以每次推送后 GitHub 会自动重新构建，不需要再点任何东西。

### 10.3 线上实测

| 项 | 结果 |
|---|---|
| 入口 | `https://xumingxian29.github.io/MYGAME/` → **200**，`text/html` |
| MIME | `index.wasm` → `application/wasm`；`index.js` → `application/javascript`；`index.pck` → `application/octet-stream` |
| 传输压缩 | wasm **39.5MB → 4.0MB**；js 280KB → 69KB；pck 1.47MB → 1.43MB（`Content-Encoding: gzip`） |
| 字节一致性 | `index.html` / `index.js` / `index.pck` 的 sha256 与本地 `build/web` **完全一致** |
| 公网地址完整启动 | 桌面配置（1280×720）打开公网地址：加载页走完 → `canvas` 挂载 → 菜单正常渲染，引擎日志 `4.7.2.stable ... single-threaded`，**控制台 0 error**。本机代理只有约 15KB/s，这一次首屏耗时 **6 分 43 秒** |
| 子路径全链路 | 把同一份产物放到本地 `/MYGAME/` 子路径（`python -m http.server --directory build/site`），Edge 模拟 844×390 + 5 点触摸：菜单 → 开始 → Lv.2 / 击杀 3 → 升级选卡，**控制台 0 error**；引擎日志 `Godot Engine v4.7.2.stable ... Compatibility ... single-threaded` |

**关于耗时的说明**：6 分 43 秒是本机出口被代理限速的结果（39.5MB wasm 已在 CDN 侧压到 4MB，仍只有 15KB/s 量级），不是站点问题；同等体积在普通宽带 / 4G 下约 3~8 秒。手机模拟那一轮（844×390 + `deviceScaleFactor=3`，显存与内存需求翻倍）在下载中途被浏览器掐断过一次，桌面配置同一地址一次通过。

### 10.4 体积与配额

| 限制 | 现状 | 余量 |
|---|---|---|
| GitHub 单文件 100MB | wasm 39.5MB | 够 |
| Pages 站点体积 ≤1GB | 约 42MB / 版本 | 够 |
| Pages 流量 100GB/月 | 首屏约 6MB，二次进入走缓存 | 约 1.6 万次首屏/月 |

### 10.5 已知限制

1. **存档不跨设备**：`user://` 落在浏览器 IndexedDB，换设备 / 换浏览器 / 清站点数据都会清空。
2. **更新有延迟**：推送后 GitHub 构建 + CDN 生效约 1~2 分钟；期间可能出现新旧文件混用，重新刷新即可。
3. **国内访问速度**：`*.github.io` 在部分网络下不稳定，需要国内访问时可换对象存储 / 自有服务器，产物不用改。
