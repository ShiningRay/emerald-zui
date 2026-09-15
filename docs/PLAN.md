# Emerald::Zui · ZUI 视口扩展开发计划

> 工作名 **Emerald::Zui**——Emerald OS 的 ZUI（Zoomable User Interface）视口扩展包：
> 把整个桌面放进无限二维画布，相机 `{x, y, zoom}` 取代固定视口，缩放即导航、
> 平移即浏览。经典桌面 = 相机锁死 `{0, 0, 1}` 的退化形态，一套代码两种模式。
>
> 定位：**独立扩展仓**，Emerald 的第一个扩展消费者。不 fork、不猴子补丁
> citrine/beryl/emerald 三仓主干；发现缺口先在本仓落地，稳定后走反哺通道（§5）。
>
> 状态：**骨架就位（2026-09-15），Z0 未动工**。本文档是唯一的规划事实源，
> 变更须同步修订。功能要点清单（P0/P1/P2，§1）已与用户对齐；
> 三条语义决策（D3）采用推荐默认，**待用户最终拍板**。

---

## 0. 目标与非目标

**目标**
- 无限画布：世界层（壁纸/图标/窗口）无边界，没有「拖到屏幕边缘」的概念。
- 相机模型：`Camera` 服务持有 `{x, y, zoom}` Signal，所见一切皆相机取景。
- 缩放即导航：滚轮以指针为锚点缩放（放大 = 深入，缩小 = 概览），不是放大镜。
- 平移即浏览：拖拽世界空白处平移，落点回写（手势中直写 DOM，松手 commit）。
- 世界坐标持久：窗口/图标存世界坐标，刷新后回到原地——空间记忆是立身之本。
- 相机飞行：任务栏点击 = 相机动画飞到窗口；⌘0 全景 overview 防迷路。
- 全部核心逻辑（相机数学/坐标换算/模式判定）**纯 CRuby 可测**（beryl F5 同款纪律）。

**非目标（v1 不做）**
- 嵌套世界（双击窗口进入「应用内部世界」，Raskin/Archy 终极形态）。
- 移动端 pinch 手势（桌面滚轮优先；wheel 原语已够）。
- 三维投影（纯 2D 缩放，不是 BumpTop/Looking Glass）。
- E7 .emap 打包形态适配（留待 emerald E7 落地后评估本仓分发形态）。

## 1. 功能要点（2026-09-15 与用户对齐）

| 层级 | 要点 | 里程碑 |
|---|---|---|
| **P0 核心身份** | ① 无限画布 ② 相机 `{x,y,zoom}` ③ 缩放即导航（锚点缩放）④ 平移即浏览（落点回写）⑤ 世界坐标持久 | Z0 / Z0 / Z0 / Z0 / Z2 |
| **P1 可用底线** | ⑥ HUD 与世界分离 ⑦ 拖拽缩放补偿（zoom≠1 手感一致）⑧ 相机飞行（任务栏=fit）⑨ ⌘0 全景 ⑩ 模式可切换（classic = 退化路径） | Z1 / Z1 / Z1 / Z1 / Z2 |
| **P2 语义缩放** | ⑪ LOD：低 zoom 窗口退化标题卡 → 色块；图标聚簇（v1.1）⑫ 嵌套语义——**明确不做** | Z3 / — |

## 2. 仓库与构建

```
emerald-zui/
  lib/emerald/zui.rb          入口（require 'emerald' 后加载本扩展）
  lib/emerald/zui/camera.rb   相机服务（纯 CRuby，§3.1）
  lib/emerald/zui/shell.rb    ZuiShell < Emerald::DesktopShell（§3.2）
  lib/emerald/zui/gesture.rb  平移/缩放手势接线（Z1，§3.4）
  lib/emerald/zui/overview.rb ⌘0 全景 + 相机飞行动画（Z1，§3.4）
  examples/zui_desktop.rb     演示入口（= 整机）
  examples/zui_desktop.html   页面壳（含 .zui-world/.zui-hud 样式；
                              上游 desktop.html 样式变更须手动跟进）
  test/                       minitest（按子系统分文件）
  docs/PLAN.md                本文档
```

- Gemfile：`citrine` / `citrine-beryl` 走 path（CITRINE_PATH/BERYL_PATH 环境变量，
  同 emerald 惯例）；**emerald 无 gemspec（应用仓），不进 Gemfile**，经 Rakefile /
  编译命令的 `-I` 与 `EMERALD_PATH`（默认 `../emerald`）上 load path。
- 编译：`bundle exec opal -c -I. -I../citrine/lib -I../beryl/lib -I../emerald/lib
  -Ilib -o examples/zui_desktop.js examples/zui_desktop.rb`（rake compile 封装）。
- 开发：`cd citrine && bin/citrine dev ../emerald-zui/examples -I ../beryl/lib
  -I ../emerald/lib -I ../emerald-zui/lib`。
- **工具链钉死**：`.ruby-version` 3.3.5（rbenv；系统 ruby 2.6 无 bundler 2.7.2——
  emerald 工具链备忘同款，命令前 `export PATH="$HOME/.rbenv/shims:$PATH"`）。
- CI：emerald 的 GitHub Actions 矩阵 + 第三步 checkout ShiningRay/emerald
  （CRuby 测试 × 4 ruby + Opal 编译验收）。

## 3. 核心子系统设计

### 3.1 Camera（camera.rb，纯 CRuby）

```ruby
cam = Emerald::Zui::Camera.new           # 内部 Citrine::Signal({x, y, zoom})
cam.get          # => { x:, y:, zoom: }  世界原点相对屏幕左上角的偏移语义：
                                       #   screen = (world + cam.xy) * zoom
cam.zoom_at(sx, sy, factor)            # 以屏幕点为锚缩放：锚点世界坐标不动
cam.pan_by(dx, dy)                     # 屏幕像素位移（除以 zoom 换算进世界）
cam.fit(rect, viewport, padding: 40)   # 飞到指定世界矩形（任务栏点击/最大化用）
cam.signal                             # 暴露 Signal 供 Effect 订阅 transform
```

- 世界/屏幕换算：`screen = (world + {x,y}) * zoom`，`world = screen / zoom - {x,y}`；
  测试锁定往返恒等。
- `zoom_at` 不动性：锚点屏幕坐标对应的世界点，缩放前后在屏幕上的位置不变
  （单测核心断言）。
- 缩放范围钳制 `MIN_ZOOM = 0.1` / `MAX_ZOOM = 4`（D3-③ 暂定有限范围）。
- 变更纪律：**只能从事件回调进入**（wheel/drag/快捷键/任务栏点击），
  不在 view/Effect 内 set（beryl F6 同款守卫意识；Camera 不渲染，天然安全）。

### 3.2 ZuiShell 两层组装（shell.rb）

`Emerald::Zui::Shell < Emerald::DesktopShell`，覆写 `view`：

```ruby
def view
  world_layer   # box(.zui-world) { wallpaper; icon_grid; each_window_frame }
  hud_layer     # box(.zui-hud)   { menubar; Taskbar; tray; toast_stack }
end
```

- **世界层方法全部继承复用**（`wallpaper`/`icon_grid`/`each_window_frame` 是
  DesktopShell 的方法，子类直接调用），不复制实现；emerald 侧若日后重命名，
  本仓编译即断——接受此耦合，反哺评估见 §5。
- **transform 直写 DOM**：camera signal **不在 view 内读**（读了会让整个世界层
  每帧重渲染）。挂载时建 Effect：`el.style.transform = "translate(...) scale(...)"` 
  （beryl `setup_text_area` 的 `owned_effects << Effect.create` 同款模式）。
  世界层容器样式 `transform-origin: 0 0; will-change: transform`。
- **fixed 定位语义注意**：CSS transform 使后代 `position: fixed` 相对容器定位——
  壁纸/图标网格在世界层内正好要随相机变换（世界语义）；HUD 各组件在容器外
  不受影响。这是方案成立的关键行为，Z0 首日浏览器验证。
- **经典模式 = 退化形态**：`viewport_mode == :classic` 时相机锁定 `{0,0,1}` 且
  wm 带 viewport——行为与 emerald 桌面逐像素一致（Z2 回归验收标准）。

### 3.3 窗口管理器世界语义

- ZUI 模式：`@wm = Beryl::WindowManager.new(viewport: nil)`——`clamp_geom` /
  `snap_zone` 对 viewport 判空（beryl window.rb:333/350），传 nil 一次关掉
  视口钳制与边缘吸附（无限画布没有「屏幕边缘」）。
- 最大化重定义（D3-②）：`toggle_max` 不再改几何，改为 `camera.fit(窗口矩形)` 
  ——「最大化」= 让窗口充满视野。v1 做法：ZuiShell 覆写开窗接线，
  `on_maximize`/`on_head_dblclick` 改接相机（wm.frame 的 **opts 可覆写**，无需动 beryl）。
- 窗口几何一律世界坐标，`default_geometry` / 级联偏移语义不变（x/y 即世界坐标）。

### 3.4 输入与导航（gesture.rb / overview.rb，Z1）

| 输入 | 行为 | 实现 |
|---|---|---|
| 滚轮（世界层上） | 以指针为锚缩放 | beryl L1 `wheel` 原语 → `cam.zoom_at(sx, sy, factor)` |
| 拖拽世界空白处 | 平移 | mousedown 命中容器自身（非窗口/图标）→ 手势中直写 transform style，松手 `pan_by` commit（落点回写，beryl setup_drag 同款） |
| 任务栏点击 | focus + 相机飞到窗口 | `wm.focus` 后 `cam.fit(geom, viewport)`；动画用 Beryl::Timer lerp（每帧 set 属事件回调链，F6 安全） |
| ⌘0 | 全景：fit(全部窗口 bbox)；空桌面回 `{0,0,1}` | `Emerald.hotkey.register('meta+0')` |
| 双击窗口标题栏 | 最大化 = camera fit（§3.3） | frame opts 覆写 |

### 3.5 拖拽缩放补偿（beryl 缺口，Z1 关键路径）

**问题**：beryl `setup_drag` 的几何是 `offsetLeft + (clientX - sx)`——前者是布局
（世界）坐标，后者是屏幕像素。zoom ≠ 1 时拖拽漂移（zoom=2 窗口跑双倍距离）。
**松手回写时误差已烤进 payload**，纯 emerald 侧无法干净修复。

- **正道（beryl PR）**：drag 原语加可选 `drag_scale:` prop——mousedown 时取值，
  `ldx/ldy` 除以它再参与 `compute_geom` 与 live 样式跟随。附 beryl 侧回归测试，
  走正常分支 → PR → CI 流程。
- **过渡（本仓，可选）**：借 `on_front`（mousedown 触发）快照 `wm.geometry(id)`，
  回调里反推：`world = snapshot + (payload - snapshot) / zoom`。脆弱（依赖
  mousedown 先于 drag 的时序），beryl PR 合并即删，代码里必须标注。

### 3.6 持久化

- 相机：新 key `emerald.camera.v1`（`{x, y, zoom}`），防抖写回沿用
  SettingsStore/adapter 模式。
- 窗口/图标坐标沿用 emerald 既有 key，**坐标系语义随模式变化**（classic=屏幕 /
  zui=世界）。v1 简单处理：切换模式时重置窗口布局并 Toast 提示，不做双坐标系
  迁移（§8 风险表）。

### 3.7 LOD 语义缩放（Z3，stretch）

- zoom < `LOD_CARD = 0.4`：窗口只渲染标题卡（content 插槽不调用）——实例归
  registry 管（emerald D3），不渲染 ≠ 销毁，放大即回。
- zoom < `LOD_BLOB = 0.15`：只剩色块 + 标题文字。
- 实现位置：ZuiShell 覆写 `each_window_frame`，按 `camera.signal.get[:zoom]` 
  分档（此 Effect 订阅相机——LOD 只在跨档时改变渲染结构，档内变换仍走
  transform 直写，不产生重渲染风暴）。
- 图标聚簇（zoom < 0.4 按区域聚合为簇图标）：v1.1。

## 4. 关键设计决策

| # | 决策 | 理由 / 依据 |
|---|---|---|
| D1 | **独立扩展仓**，非 emerald 内部分支 | 用户定调（2026-09-15）。Emerald 是 OS 产品仓保稳定，ZUI 是范式实验；隔离 emerald E7 动工期的 shell.rb 交叉。代价：依赖 DesktopShell 内部方法的继承复用（§5 反哺评估） |
| D2 | **相机 = 单容器 CSS transform**，非逐窗投影 | `offsetLeft` 是布局坐标不受 transform 影响（窗口定位天然是世界坐标）；transform 直写 DOM = 单 Effect 订阅，零重渲染；GPU 合成器加速 |
| D3 | **三条语义决策（2026-09-15 拍板）**：① 窗口随相机缩放（Pad++ 正统）② 最大化 = camera fit ③ 缩放范围有限 0.1×–4× | ① 保 ZUI 辨识度；② 保留肌肉记忆入口且天然适配无限画布；③ 防迷路（ZUI 两大历史死因之一） |
| D4 | **经典模式 = 相机退化形态一套代码** | 不设平行实现；`{0,0,1}` + viewport 钳制即经典桌面，Z2 逐像素回归验收 |
| D5 | **不猴补三仓**，缺口走反哺通道 | 与 emerald PLAN「不 fork、不猴子补丁」同纪律；beryl `drag_scale` 走正式 PR（§5） |

## 5. 与 emerald/beryl 的边界（反哺清单）

| 能力 | 目标仓 | 形态 | 触发 |
|---|---|---|---|
| `drag_scale:` 拖拽缩放补偿 | beryl | 正式 PR（prop + 回归测试） | **Z1 关键路径** |
| DesktopShell 世界/HUD 拆层 hook | emerald | 评估：子类继承够用则不动；若 emerald 重构 view 拆出 `world`/`hud` 两个可覆写点，本仓切换为消费方 | Z1 后评估 |
| citrine 内核 | — | **零需求**（红线不动） | — |

## 6. 里程碑与验收

| 里程碑 | 内容 | 验收 | 预估 |
|---|---|---|---|
| **Z0** spike | camera.rb（§3.1 全 API + 单测）+ ZuiShell 世界层容器 + wheel 锚点缩放 + 空白拖拽平移（落点回写）。**已知窗口拖拽手感漂移，不修** | 单测：锚点不动性/钳制/fit/往返换算；浏览器：缩放平移手感主观验收（**唯一标准：缩到全景再放大回某窗口，是否比 ⌘` 循环更快更爽**）；`bundle exec rake` 绿 | 0.5–1d |
| **Z1** 可用底线 | beryl `drag_scale` PR（或过渡方案）+ HUD/世界分层定稿 + 任务栏相机飞行 + ⌘0 全景 + 最大化 = fit | 浏览器：zoom ∈ {0.25, 0.5, 1, 2, 4} 五档下拖窗/缩放窗口手感与光标一致；⌘0 后全部窗口入视野；任务栏点击飞行到位 | 1–2d |
| **Z2** 模式与持久 | Settings 视口模式开关（`settings viewport_mode`）+ 相机持久化（`emerald.camera.v1`）+ 模式切换布局重置提示 | 浏览器：ZUI 下关机刷新，相机/窗口/图标原地还原；切回经典模式与 emerald 桌面行为逐像素一致（D4 回归） | 1d |
| **Z3** 语义缩放（stretch） | LOD 标题卡（0.4）/色块（0.15）+ 跨档渲染结构切换 | 浏览器：0.3× 全景下 20 个窗口可辨识、点击卡片飞行放大还原 | 2d+ |

关键路径：Z0（验手感，可否决后续）→ Z1（beryl PR 是关键路径上的外部依赖，
第一天就提）→ Z2 → Z3。整体约 **1 周**专职量级（不含 Z3）。

## 7. 测试策略

1. **单元（纯 CRuby，`bundle exec rake test`）**：Camera 数学（锚点不动/范围
   钳制/fit 居中/坐标往返恒等）；ZuiShell 组装断言（StringRenderer：世界层
   容器存在、窗口在其中、HUD 在其外）；模式开关行为；持久化 round-trip。
2. **Opal 编译验收**：`rake compile`（CI 门禁）。
3. **浏览器 E2E**：手感项按 Z1 验收清单五档 zoom 逐项过；回车用合成
   KeyboardEvent（ZCode 内置浏览器 `press("Enter")` 不派发 keydown，
   citrine 已知环境缺陷非框架 bug）。
4. **演示页即整机**：`examples/zui_desktop.rb` 就是产品本体。

## 8. 风险与坑位映射

| 风险/坑 | 应对 |
|---|---|
| 相机 signal 在 view 内被读 → 平移/缩放每帧整层重渲染 | transform Effect 直写 DOM（setup_text_area 模式）；手势期间直写 + 松手 commit（落点回写） |
| 文本在缩放动画中位图模糊 | 浏览器合成器行为，静止时重新光栅化即清晰——接受 |
| 方案前提：CSS transform 不影响 `offsetLeft`（布局坐标） | Z0 首日浏览器验证；若被推翻，退回「逐窗投影」备选（渲染侧乘 zoom，代价是相机变更全窗重渲染） |
| F6 无限重入 | camera/wm 变更只从事件回调进入；wm 自带 `assert_outside_effect!` |
| F4 子组件自焚 | app 实例归 registry（emerald D3 继承）；LOD 不调用 content 插槽 ≠ 销毁实例 |
| beryl 拖拽漂移 | §3.5 双轨：正式 PR（关键路径第一天提）+ 可选过渡方案 |
| 与 emerald E7（Service/View 重构）交叉 | **E7 已随上游同步落地**（emerald `611371a`，2026-09-15）：shell.rb +175 行但 view/wallpaper/icon_grid/each_window_frame 等继承缝逐一核对未变，本仓 rake 双绿。残余关注点：E7 带来 pkg/Service 新层，ZUI 的 .emz 分发形态可提前评估（原列 v 后评估项） |
| **迷路（ZUI 历史死因）** | 非可选项内建：⌘0 全景 + 有限缩放范围 + 任务栏飞行 |
| 切模式后坐标系语义混乱 | v1 切模式重置窗口布局 + Toast 明示；不做双坐标系迁移 |
| 用户晕动/不习惯 | Settings 开关默认 classic；ZUI 需主动开启 |

## 9. 实施记录

- **2026-09-15 上游同步**：beryl → `f0cd5e8`（菜单坐标 Event#raw 修复等 4 项）；
  emerald → `17ec8a2`（**E7 落地**：.emz 包管线 / Installer / 编译缓存 /
  Service 生命周期 + README）；citrine 无新提交（`75d8bab`）。本仓
  `bundle exec rake` 双绿，DesktopShell 继承缝（view/wallpaper/icon_grid/
  each_window_frame/menubar/tray/toast_stack）核对无漂移。
- **2026-09-15 Z0 落地（32 项全绿）**：D3 三决策按推荐默认拍板（见 §4）。
  ① `camera.rb`——Camera 全 API（锚点缩放/平移/fit/双向换算/钳制 0.1×–4×/
  F6 四 op 守卫），22 项测试锁契约。**契约裁决**：原 fit 字面公式与
  换算恒等式不自洽，按恒等式 + 中心对齐实现（`x' = vw/(2z') − cx`，
  注释留痕于 camera.rb:78-84）。② `shell.rb`——ZuiShell 两层组装
  （世界层/HUD 层），相机 Effect 直写 DOM 零重渲染，滚轮锚点缩放 +
  空白拖拽平移（落点回写），覆写 `current_viewport` 恒 nil 关掉 wm
  钳制/吸附（§3.3），9 项测试。③ **beryl `drag_scale` 已提 PR
  [#2](https://github.com/ShiningRay/beryl/pull/2)**（纯 CRuby
  `Beryl::DragGeometry.compute` + prop，94 项全绿）——Z1 关键路径外部
  依赖提前解除。
  **Z0 待人工验收**：浏览器手感（缩到全景再放大回窗口是否比 ⌘` 快）、
  滚轮在可滚动内容上误缩放、offsetLeft 前提验证。
- **2026-09-15 Z0 浏览器验收与两处修复**（合成事件实证调试）：
  ① **平移方向反转**——`pan_by` 公式用了「相机跟随光标」的减号约定，
  改为抓取语义 `x' = x + dx/zoom`（内容跟随光标；camera.rb / shell.rb
  手势跟随 / camera_test「内容跟随光标」断言补反例一并修正）。
  ② **滚轮缩放浏览器端必炸**（平移提交同款暗伤）——根因是 Opal 对带
  kwargs 的方法无条件 extract_kwargs：`Citrine.dispatch_callable` 的
  `bind:` 关键字参数把末位位置参数 Hash（事件 payload）抽走，arg 变 nil
  → `nil[:x]` NoMethodError。**CRuby 单测不可见**（花括号 Hash 在 CRuby
  永远绑位置参数）。影响面含 beryl 窗口拖/放 live 回写；修复 =
  bind 改位置参数，citrine 分支 `fix/dispatch-callable-kwargs`
  （[PR #30](https://github.com/ShiningRay/citrine/pull/30)，315 项全绿，
  附 payload 契约文档测试）。浏览器回归全过：滚轮四档缩放精确 e^0.12
  递增、锚点漂移 0.00px、松手不打回、beryl 拖窗跟手精确 (120,60)。
  **方法论记录**：Opal/CRuby 语义陷阱类 bug 只能靠浏览器 E2E 或
  编译产物审查发现，单测门禁天然盲区。
  **待办**：beryl PR #2（drag_scale）与 citrine PR #30 合并后接 Z1；
  滚轮在可滚动窗口内容上的误缩放仍未做 scrollable 感知（浏览器验收定夺）。
