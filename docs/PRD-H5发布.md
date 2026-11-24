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
| D | 输入 | 仅键盘（WASD + 空格） | 桌面浏览器可用；手机无法操作 |
| E | 导出模板 | 未安装 | 必须下载 Web 导出模板，否则导出按钮不可用 |
| F | 物理引擎声明 | `3d/physics_engine="Jolt Physics"` | Web 模板不含 Jolt，2D 游戏用不到，应移除以避免启动告警 |
| G | 存档持久化 | `user://records.json` | Web 下映射到浏览器 IndexedDB，需确认刷新后不丢档 |

---

## 2. 目标与非目标

### 目标

1. 在桌面浏览器（Chrome / Edge，支持 WebGL2）打开链接即可游玩，操作与桌面版一致。
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

### R4 · 移动端触屏输入（P1，可独立延期）

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

### R7 · 导出与部署（P0）

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
| S5（可选） | R4 虚拟摇杆 + 竖屏提示 | 手机可玩 |

S1–S4 为"桌面浏览器可玩"的最小闭环；S5 独立，可延后。

---

## 8. 实施记录与验收结果（2026-11-24）

### 落地清单

| 需求 | 状态 | 实际做法 |
|---|---|---|
| R1 渲染后端 | 完成 | `config/features` → `GL Compatibility`，并显式写 `rendering_method` 与 `rendering_method.mobile` |
| R2 中文字体 | 完成 | Noto Sans SC 子集（ASCII + GB2312 全表 + 项目文案共 6957 字），**7.95MB → 1.46MB**；`UiKit.font()` 改返回 `FontFile`，缺失时回退 `ThemeDB.fallback_font` |
| R3 视口自适应 | 完成 | 基准 1280×720 + `canvas_items` / `expand`；竖屏窄屏显示"请横屏游玩" |
| R4 虚拟摇杆 | **未做（P1 延期）** | 桌面浏览器可玩，手机仍需实体键盘 |
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

1. **手机不能操作**：R4 摇杆未做，触屏无输入手段（PRD 原定 P1）。
2. **昵称生僻字可能显示方块**：字体做了子集化，只覆盖 GB2312 常用字。
3. **首屏受网速影响**：10MB 传输在 4G 下约 5~15 秒。
4. **不支持 `file://` 直接打开**：必须经 HTTP（`python serve.py`）。

### 复现命令

```bash
# 导出
godot --headless --path . --export-release "Web" build/web/index.html
# 预览
python serve.py 8080     # 打开 http://127.0.0.1:8080/
```

导出前必须先建好 `build/web` 目录，Godot 不会自动创建，否则报"目标文件夹不存在"。
