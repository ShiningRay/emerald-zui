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
| **P1 可用底线** | ⑥ HUD 与世界分离 ⑦ 拖拽缩放补偿（zoom≠1 手感一致）⑧ 相机飞行（任务栏=fit）⑨ ⌘0 全景 ⑩ 模式可切换（classic = 退化路径）⑪ **形态态机：窗口⇄图标同一对象两形态（B 方案）** | Z1 / Z1 / Z1 / Z1 / Z2 / **Z1.5** |
| **P2 语义缩放** | ⑫ LOD：低 zoom 窗口退化标题卡 → 色块；图标聚簇（v1.1）⑬ 嵌套语义——**明确不做** | Z3 / — |

## 2. 仓库与构建

```
emerald-zui/
  lib/emerald/zui.rb          入口（require 'emerald' 后加载本扩展）
  lib/emerald/zui/camera.rb   相机服务（纯 CRuby，§3.1）
  lib/emerald/zui/projector.rb 世界↔小地图投影器（纯 CRuby：等比映射/逆映射/矩形并集）
  lib/emerald/zui/minimap.rb  小地图组件（窗块缩略 + 相机取景框，点击/拖拽导航）
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

### 3.8 形态态机：窗口即图标（B 方案，2026-09-15 定案）

> 用户定调：**在 ZUI 版本里，图标和窗口是同一对象的两种形态，不是两种控件。**
> 红利：图标形态是实例的**活跃视图**（live view），垃圾桶空满、邮箱未读数、
> 时钟指针等特殊效果 = 普通的状态驱动渲染，天然实时、无需小地图式克隆快照。

**核心抽象**：App 实例持有 `form ∈ {:window, :icon}` 与两套几何——窗口几何
（wm 记录）与图标几何（世界坐标，可拖拽驻留）。形态切换即对象在两个表达态
之间的变形（§3.9 动效），全程同一实例、同一批 state signal，不 launch 新实例。

```
                ┌─ morph（FLIP 变形 320ms）⇄ ─┐
  实例.form ───┤                              ├── 同一 App 实例、同一 state
     :window   └─ 最小化按钮 / 双击图标触发    │   图标形态渲染 icon_view（默认
       │                                     │   降级为 glyph + 标题徽标）
       └─ wm 记录 + WindowFrame + content    └─ 世界坐标 live tile + icon_view
```

- **App API 扩展**（反哺候选，ZUI 先行验证）：
  ```ruby
  class Emerald::App
    attr_accessor :form                      # 默认 :window
    attr_accessor :icon_geometry             # 图标形态世界坐标 {x, y}
    attr_accessor :window_geometry_backup    # 缩成图标时暂存的窗口几何
    def icon_view                            # 图标形态视图（覆写即活图标）
      # 默认：app glyph + 标题（无声明即兼容降级）
    end
  end
  ```
- **渲染分发**：`each_window_frame` 改为按 form 分派——`:window` 走 wm.frame
  原路径；`:icon` 渲染世界层 live tile（absolute 于 icon_geometry，单击选中、
  双击 morph 回窗口、可拖拽换位——**顺带交付运行中应用的图标拖换位**，静态
  启动器不受益）。D4 守卫（`wm.windows.include?`）按 form 重写，close 链路
  （wm.close + registry.dispose）不变。
- **wm 关系**：wm 只登记窗口形态实例；形态切换 window→icon 时 `wm.close`
  （实例留在 registry，与 close 销毁语义分立——这是与现有最小化最大的语义
  差异）；icon→window 时 `wm.open` 恢复（几何取 backup 或级联）。
- **桌面种群**：静态启动器图标（未运行应用，非实例，维持现状）+ 活图标形态
  （运行实例）+ 文件图标，三者视觉同构、对象本质不同。
- **活图标示例（dogfood 计划）**：`Emerald::Zui::Apps::Clock` 演示应用——
  窗口形态 = 模拟钟面，图标形态 = 两根指针（分钟 signal 驱动
  `transform: rotate`，秒针不渲染——省电防抖：`分`粒度 tick 即可）；
  满/空类效果（垃圾桶/邮箱）机制相同：icon_view 内读 signal → 样式/徽标。
- **与 Z3 LOD 的关系**：形态态机是**用户驱动**的对象级语义，LOD 是**缩放
  驱动**的渲染级优化，两轴正交；图标形态可视作窗口 LOD 链的语义终点。

### 3.9 形变动效（形态切换的执行层）

**2026-09-16 复查修订（用户验收反馈：启动无形变 / 关闭瞬间消失 / 一应用两图标）**

- **表征互斥**：`icon_grid` 覆写——应用有实例（任意形态）时不渲染启动器图标；
  槽位交给实例的图标形态，窗口形态时槽位空着（图标已"变成"窗口飞走）。
- **槽位恒定**：锚位在**启动时**确定——`launcher_rect_for` DOM 实测启动器
  rect（图标与世界容器两 rect 相减 ÷ zoom，天然免疫相机 transform），
  同应用已有实例或测不到时级联兜底；一经确定永驻（可拖拽换位）。
- **启动即形变**：`open_with_morph`——建实例 → 锚位 → form :window（启动器
  随之让位）→ bump morph_tick → 幽灵从图标矩形飞涨到窗口矩形 → 收尾
  `wm.open` 出窗（形变期两端都不渲染，只有幽灵）。
- **✕/⌘W = 收起为图标**（D10）：`close_window` 在 ZUI 改为 `morph_to_icon`；
  真退出 `quit_app`（⌘Q / 菜单「退出当前应用」）——摘守卫/去重记录 →
  摘窗 → dispose → 启动器回归。
- 两个浏览器实证踩坑（已修，注释留痕）：① **backtick JS 字符串字面量里的
  `#{...}` 插值在 Opal 下不求值**（实参成字面 `"sel"`，querySelector 落空）
  ——选择器一律走 Ruby 字符串 → Native 方法传参；② tile 常驻启动器槽位后
  被 `.icon-grid`（页面壳 CSS 给了 `z-index: 1`）盖住、点击被网格接走——
  tile 显式 `z-index: 2`。
- FLIP 幽灵元素（§3.8 的形态切换即此前「窗口⇄图标动效」任务的 B 方案化）：
  世界层内、absolute 定位于源形态世界矩形，只动画 `transform`（中心差
  translate + 非均匀 scale + border-radius + 内容交叉淡化——非均匀 scale
  即「变形」观感）；两端同在世界 transform 容器内，相机无关零换算。
- 纯数学段：`Emerald::Zui::Morph.transform(from, to)`（CRuby 可测）；
  Opal 执行段 `Morph.fly(world_el, panel_el, from_rect, to_rect, on_done)`
  （cloneNode 深克隆剥 id、transitionend + 兜底定时器、CRuby 下直接 on_done）。
- 防重入 @morphing 标志；动画期跳过 form 渲染（两端都不渲染，只有幽灵）。
- 任务栏最小化按钮暂走经典 toggle_min（HUD 在 transform 外，screen/world
  换算另需一道，列 Z1.5 之后评估）。

## 4. 关键设计决策

| # | 决策 | 理由 / 依据 |
|---|---|---|
| D1 | **独立扩展仓**，非 emerald 内部分支 | 用户定调（2026-09-15）。Emerald 是 OS 产品仓保稳定，ZUI 是范式实验；隔离 emerald E7 动工期的 shell.rb 交叉。代价：依赖 DesktopShell 内部方法的继承复用（§5 反哺评估） |
| D2 | **相机 = 单容器 CSS transform**，非逐窗投影 | `offsetLeft` 是布局坐标不受 transform 影响（窗口定位天然是世界坐标）；transform 直写 DOM = 单 Effect 订阅，零重渲染；GPU 合成器加速 |
| D3 | **三条语义决策（2026-09-15 拍板）**：① 窗口随相机缩放（Pad++ 正统）② 最大化 = camera fit ③ 缩放范围有限 0.1×–4× | ① 保 ZUI 辨识度；② 保留肌肉记忆入口且天然适配无限画布；③ 防迷路（ZUI 两大历史死因之一） |
| D4 | **经典模式 = 相机退化形态一套代码** | 不设平行实现；`{0,0,1}` + viewport 钳制即经典桌面，Z2 逐像素回归验收 |
| D5 | **不猴补三仓**，缺口走反哺通道 | 与 emerald PLAN「不 fork、不猴子补丁」同纪律；beryl `drag_scale` 走正式 PR（§5） |
| D6 | **窗口即图标：同一实例两形态**（B 方案，2026-09-15 用户定案） | 图标形态是实例的活跃视图，特殊效果（垃圾桶空满/时钟指针）= 状态驱动渲染；比 A 方案（两对象系统架桥 + DOM 克隆）更省、更实时、更符合 ZUI 语义；接口按 B 语义设计使 Z3 LOD 可统一 |
| D7 | **图标形态 = 第一等 live view**（`App#icon_view`，默认降级 glyph+标题） | 无声明应用零成本兼容；活图标不需要快照/保鲜机制；反哺 emerald App 基类（§5） |
| D8 | **未运行应用保留静态启动器图标**（非实例） | 桌面需要启动入口。**2026-09-16 复查修订**：启动器与实例图标形态**不并存**（见 D9）——原表述「两者同构不同质并存」作废 |
| D9 | **表征互斥 + 槽位恒定**（2026-09-16 用户复查定案） | 同一对象任意时刻只有一个表征在场上（图标 XOR 窗口）；锚位在**启动时**取该应用启动器槽位（图标在哪，窗口就从哪长出、缩回哪去），启动器在有实例时让位。修正前「启动器 + 实例 tile 并存且位置不同」= 一个应用两个图标（用户指出的缺陷） |
| D10 | **ZUI 下 ✕/⌘W = 收起为图标**，真退出走 ⌘Q / 菜单栏「退出当前应用」 | 用户定调「关闭/最小化都是窗口变形还原为图标」；为此必须补退出出口（⌘Q 键盘流 + 菜单可发现性），否则应用无法退出 |
| D11 | **桌面不放应用启动器**，启动入口收敛为启动器应用（Spotlight 式，⌘K 呼出） | 用户定调。桌面图标语义因此唯一：① VFS 文件 ② **运行中实例的收起形态**——桌面出现某应用图标即「它正开着」。启动器应用承担「看到所有应用 + 启动/聚焦/退出」 |
| D12 | **锚位改为图标列空槽自动分配**（文件图标占位 + 已分配锚位实例数，列优先 8 个一列） | 桌面无启动器槽位可测后锚位必须另立规则；一经分配永驻、可拖拽换位。索引运算一律 `Integer#div`（Opal 的 `/` 不整除，见 §8） |

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
| **Z1** 可用底线 | HUD/世界分层定稿 ✅ + 任务栏相机飞行 ✅ + ⌘0 全景 ✅ + 最大化 = fit ✅ + 任务栏最小化 = 形态切换 ✅；余 drag_scale 接线（等 beryl PR #2） | 浏览器：拖窗/缩放窗口手感与光标一致（待 drag_scale）；⌘0 后全部窗口入视野 ✅；任务栏点击飞行到位 ✅ | 1–2d（多在途） |
| **Z1.5** 形态态机（B 方案，用户定案） | form 态机 + `App#icon_view` 扩展（ZUI 侧 module 注入，反哺 emerald 待 §5 评估）+ 图标形态渲染分发/拖拽驻留 + Morph 形变（§3.9）+ Clock 活图标 dogfood | 浏览器：最小化窗口变形飞成图标（落图标几何位）；双击图标涨回窗口；拖动图标形态换位；**Clock 图标形态的指针与窗口形态同步走字**；多实例各自独立图标形态；单测：Morph 数学、form 分发、backup 几何恢复 | 2–3d |
| **Z1.6** 启动器应用（Spotlight 式） | 桌面撤下应用启动器（只留文件图标）+「启动器」应用：列表带状态（未运行/运行中/已收起）+ 主操作（启动/聚焦/显示）+ 行内「退出」；搜索过滤、↑↓ 导航、回车执行、Esc 收起自己；⌘K 呼出；锚位改图标列空槽分配；`ctx[:zui]` 服务面（launch/quit/focus/restore/collapse） | 桌面 0 个应用启动器；⌘K 列表全应用带状态；输入过滤且焦点不丢；回车/行内按钮启动；行内退出真关窗；Esc 收起启动器成图标；两实例收起槽位 (16,123)/(16,206) 不重叠；双击图标涨回 | 1d | ✅ 落地 |
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
| 形态切换误用 close 语义 | window→icon 走 `wm.close` + 实例留 registry，与 close（+registry.dispose）代码路径必须分开；单测锁定 dispose 不被形态切换调用 |
| form 渲染分发漏守卫 | D4 守卫改写为按 form 分派后，关闭链路（✕/⌘W）回归测试锁定 |
| **Opal 的 `/` 不做整除**（`1 / 8` = 0.125，CRuby 是 0） | 槽位/索引/分页一律 `Integer#div`；CRuby 单测天然发现不了——浏览器实证：图标槽位落在 27.75px |
| **块外读信号 → 整树重建** | 视图里读信号的表达式必须在**各自的块内**：`rows = filtered_apps` 写在块外会让订阅落在视图根块，每次输入都重建整树、输入框被摘了再挂回（焦点丢失、只能输一个字）。MutationObserver 实证 |
| 行内按钮与整行点击竞争 | 行按钮 on_click 先 `stop_propagation` 再执行（否则「退出」关掉实例后，行处理器按「已变回未运行」把它重新启动） |
| 双击图标双触发（**已定位，2026-09-15**） | 根因：beryl `setup_dblclick`（renderer.rb:183）与 citrine `EVENT_DEFS`（dom.rb:101）在**同一挂载路径各绑一次**，一次物理双击 = 2 次处理器（浏览器打点实证：launch_app×2，单例应用挡住第二发才只见于多实例）。正道 = beryl 删 `setup_dblclick`（PR #2 合并后单独提删 + 回归测试）；过渡 = ZuiShell `launch_app` 200ms 同窗去重守卫（已落地，带参启动豁免），citrine 侧修复后守卫退化为兜底 |

## 9. 实施记录

- **2026-09-16 Z1.6 启动器应用落地**（用户定调：桌面不放启动器）：`icon_grid`
  只渲染 VFS 文件；新增 `Emerald::Zui::Apps::Spotlight`（⌘K 呼出、单例）——
  列表状态取 `instances_of`（未运行/运行中/已收起）、主操作按状态路由
  （启动/聚焦/显示）、行内「退出」走 quit；输入过滤用 text_input 双向绑定；
  ↑↓ 循环、回车执行、Esc 收起自身。锚位改图标列空槽分配（D12），启动不再
  有形变（桌面无源图标；收起/涨回形变保留）。`ctx[:zui]` 服务面落地（D10），
  并把 `:launch` 明确路由到 shell（registry.launch 只建实例，R2）。
  踩坑三条（§8）：Opal `/` 不整除、块外读信号致整树重建（输入只进一个字）、
  行按钮需 stop_propagation。测试 142 项全绿（+17）。浏览器端到端验收：
  桌面启动器 0、列表 7 应用带状态、过滤保焦点、回车启动、行内退出真关窗、
  Esc 收起、槽位列优先不重叠、双击涨回，零 pageerror。

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
- **2026-09-15 小地图落地**（`1eeb63e`，61 项全绿）：防迷路三件套之二。
  `Camera#center_on` + `Projector`（世界↔小地图等比映射）+ `Minimap` 组件
  （bounds 恒 = 窗口 ∪ 相机取景框，取景框永不出图）。**浏览器实证抓到框架
  级坑**：`Minimap.new(...).view` 内联挂载不走 `render_component`，
  on_mount 不触发、画布零监听（点击/拖拽导航静默失效、console 无报错）——
  组件挂监听必须 `render(类, props)`（shell.rb hud_layer 已改，注释留痕）。
  复验全过：点击导航世界点落视口中心零误差、拖拽跟手、松手稳定。
  **待查**：双击桌面图标一次开出两个应用实例（3 次 dblclick → 4 窗，
  两次复现）——疑似 emerald 图标双击/单击竞争或监听器重复，与小地图无关。
- **2026-09-15 小地图 v2（用户验收反馈驱动，69 项全绿）**：① **拖拽
  「呼吸」修复**——根因：bounds 随取景框移动持续重拟合比例尺，光标下
  世界点漂移；修法：两段式冻结（@drag_projector 普通 ivar，拖拽期显示
  与换算同走冻结快照，松手恢复动态）。② **内容缩略图**——DOM 深克隆
  方案：shell 给每窗挂 `zui-win-<id>` 挂钩类（sanitize 与 querySelector
  双侧一致，防多实例 id 的 `#` 被当 id 选择器），minimap 用无 block 的
  key 锚点盒 + 命令式填充（外来子节点存活关键：无 key 时 ReusePool 按
  位置对位会错配），信号 Effect（几何/z 序）+ 1200ms 定时保鲜双通道，
  克隆剥 id、pointer-events 全断。③ **回家按钮**（⌂ → `Camera#home`）。
  浏览器验收待复验项：拖拽静止感、缩略图克隆实际效果。
- **2026-09-15 Z1.5 落地（B 方案态机，114 项全绿）**：四路并行——
  ① **app_form.rb**：`morph_to(target, window_geometry:)` 纯状态段（backup
  一次性消费、非法形态 raise、同形态 no-op、icon_slot 级联数学），实例侧
  零副作用（wm/DOM 归 shell，D2 分层）。② **shell.rb**：form 分派渲染
  （live tile 契约类 `zui-iconform-<id>`、单击选中/双击涨回/拖拽驻留两段式）；
  window_frame **直连 WindowFrame** 复刻 wm.frame 只换 on_minimize（beryl
  硬接 toggle_min，kwargs 覆盖不可靠——Opal 显式关键字映射才可测）；morph
  执行管 backup/级联/wm.close+open（实例留 registry）；`launch_app` 200ms
  去重守卫（带参豁免、图标形态单例再启动优先涨回）。③ **morph.rb**：
  transform 纯数学 + fly 执行段（cloneNode 剥 id、transitionend + 定时器
  双保险收场、`--morph-ms` 变量注入、to_rect 可选 radius 圆角形变、
  `Morph.morphing?` 全局防重入）。④ **Clock dogfood**：分钟粒度 signal
  （`Clock.snap`/`hand_angles` 纯函数：时针 30°/时+0.5°/分爬行），tick 链
  挂 boot/deactivate——**关键发现：app 实例经 content 插槽渲染时
  on_mount 不触发**（citrine 只在 render_component 跑 mount hooks，与小
  地图 render(类) 修复同一框架性质）；窗口形态钟面 / 图标形态双指针共享
  signal 原地重渲染。⑤ **双击双触发根因定位**（§8 更新）：beryl 与
  citrine 双绑 dblclick，反哺 = PR #2 合并后删 beryl setup_dblclick。
  **浏览器验收待办**：morph 幽灵动画观感、tile 拖拽手感、去重守卫对真实
  双击事件流覆盖、Clock 双形态同步走字。
- **2026-09-16 Z1.5 浏览器验收（通过）**：两个上游阻塞先修——① citrine
  dispatch_callable（PR #30 已并 main，本地工作树 cherry-pick -n 跟进）；
  ② beryl chrome 按钮 camelCase `e.stopPropagation`（Citrine::Event 只有
  snake_case，浏览器点最小化即 raise、morph 入口全断）→ PR
  [#4](https://github.com/ShiningRay/beryl/pull/4)。验收（逐帧 rAF 采样
  20 帧/315ms 飞行/收尾滞后 19ms）：
  - **形变**：ghost scale 1 → 0.275/0.2588（= 88/320 与 88/340，**非均匀
    = 可见变形**）单调递减，内容透明度 1 → 0.12 交叉淡化，终点 0 幽灵
    0 面板 1 tile（88×88 @ 窗口原位）——「不是凭空出现」达标；
  - **涨回**：双击 tile 反向形变，几何精确恢复（180,120,320×340）；
  - **活图标**：tile 指针与现实时间一致；测试时间 10:10 时 tile 与窗口
    形态指针同刻同角（同步走字）；分钟边界实测走字 ✓
  - **拖拽驻留**：tile 拖 (+200,+130) 落点精确、涨回再缩起位置保持
    （persistAcrossForms ✓）；
  - **多实例**：两时钟两 tile、各有表盘、位置互异；
  - **连点 5 次**：并发幽灵恒 ≤1、终态形态唯一；
  - **回归**：滚轮/平移（dispatch_callable 修复生效，松手不打回）、
    去重守卫（物理双击 +1 窗）、console 零 pageerror。
  - **非 bug 观察**：ZUI 下最大化不改几何（D3：最大化 = camera fit，
    Z1 未实现）；ghost 圆角恒 10px（窗口与 tile 圆角相同，无可形变）。
  - 遗留：任务栏最小化按钮仍走经典 toggle_min（HUD 在 transform 外需
    另做 screen→world 换算）。
- **2026-09-16 表征互斥修订与验收（用户复查驱动）**：用户指出「启动无形变、
  关闭瞬间消失、同一应用两个图标」——根因是按 D8 把启动器当独立对象。
  修订见 §3.9 修订块 + D9/D10，代码落 shell.rb（icon_grid 覆写 + 锚位在
  启动时取启动器槽位 + open_with_morph + ✕ 收起 + quit_app/⌘Q/菜单项）。
  浏览器实测（逐帧 rAF 采样）：
  - **启动**：21 帧幽灵，scale 1 → 4/4.918（非均匀放大）→ 窗口；此后启动器
    消失（表征互斥）；
  - **✕ 收起**：20 帧幽灵、scale 递减 → tile 落回启动器原槽位（实测
    world (16,456) = 启动前启动器 rect (16,455.6)）；
  - **双击 tile**：涨回窗口，几何恢复 (180,120)，tile 消失；
  - **⌘Q**：启动器回归、实例销毁、零 pageerror；
  - **回归**：再启动→最小化 = 单一表征（无重复图标）。
  - 修复两个 Opal/DOM 坑（§3.9 修订块记录）：backtick 内字符串插值不生效、
    tile 被 `.icon-grid` 的 z-index 压住导致点击被截。
  - 测试：120 项全绿（新增 6 项锁定新不变量：启动器让位/回归、✕ 收起不
    dispose、⌘Q 销毁、锚位在启动时定且不随窗口移动、菜单项）。
- **2026-09-16 上游 tip 泄漏修复**（用户实测「关闭后 tip 到处都在」）：
  beryl `setup_tip` 的气泡挂在 body、靠 mouseleave 回收——节点在悬停中被
  卸载/重渲（关窗、形态切换、响应式重跑）时该事件不触发，气泡永久残留。
  修法：回收注册为 `node.owned_effects` 的 cleanup（节点销毁随 Effect
  dispose 执行）+ mouseenter 挂新气泡前清扫残留 `.b-tip`。
  PR [#5](https://github.com/ShiningRay/beryl/pull/5)；浏览器实证：悬停 ✕
  出现「关闭」→ 点击关闭后计数 0；悬停+重渲 5 轮无累积（修前每轮累积）。
- **2026-09-16 Z1 导航收尾**（无上游依赖，全部本仓落地）：
  ① **相机飞行**（`with_flight`）——给世界层挂 `.is-flying` 的 CSS transition
  （280ms）+ 强制 reflow 后再改相机，浏览器补间到位；CRuby 直接改相机
  （单测断言结果）。
  ② **任务栏改道**（`TaskbarBridge` 装饰 wm，不 fork beryl 组件）：点激活窗
  = 形态切换（与 ✕ 同语义，收起为图标）、点后台窗 = 聚焦 + 相机飞行。
  ③ **⌘0 全景**：窗口 ∪ 图标形态实例的并集 fit（空桌面回 home）。
  ④ **最大化 = 相机 fit**（D3 定案落地）：□ 与标题栏双击都改为「飞到该窗
  充满视野」——wm.toggle_max 依赖视口几何，ZUI 下 viewport 恒 nil 故弃用。
  浏览器实证：□ 点击 → zoom 2.643（精确 fit）、任务栏前台/后台两路、
  ⌘0 → zoom 1.143（两窗入视野）；形态态机验收全项无回归。测试 129 项全绿
  （新增 9 项：桥接透传/改道、全景含图标形态、空桌面 home、最大化 fit、
  ⌘0 注册）。
- **2026-09-15 B 方案定案（形态态机）**：用户决策——ZUI 版本**窗口即图标，
  同一对象两种形态**（§3.8/§3.9，D6–D8）。此前派出的 A 方案（两对象系统架
  FLIP 桥）代理任务被叫停作废，Morph 执行层设计吸收进 §3.9。新增 Z1.5
  里程碑：form 态机 + `App#icon_view` + 图标形态渲染/驻留 + Morph 形变 +
  Clock 活图标 dogfood。活图标红利（垃圾桶空满/邮箱未读/时钟指针）=
  状态驱动渲染，小地图克隆快照机制不受影响（缩略图另有定位）。
- **2026-09-15 小地图第一半程（纯逻辑层落地）**：① `Camera#center_on`
  （保缩放把世界点对到视口中心，F6 守卫同款；契约 `x' = vw/(2z) − wx`）。
  ② `projector.rb`——`Emerald::Zui::Projector` 纯 CRuby 值对象：世界包围盒
  ↔ 小地图像素框等比映射（短轴居中留白，padding 内缩）、`to_world` 逆映射、
  `union` 窗口矩形并集（空 → 零矩形）；退化 bounds（w/h ≤ 0）按 1 算。
  ③ 单测 41 项（camera +5 含 F6 扩展断言、projector 15 项新增），
  `bundle exec rake` 双绿（minitest 51 项 + Opal 编译入包实证）。
- **2026-09-15 小地图第二半程（组件与集成落地）**：① `minimap.rb`——
  `Emerald::Zui::Minimap`（HUD 右下角）：窗块缩略 + 相机取景框渲染，
  bounds 恒 = 窗口矩形 ∪ 取景框（取景框永不出图，空世界不空窗）；
  点击/拖拽画布 = `to_world` 逆映射 → `Camera#center_on` 保缩放飞到该世界点
  （mousedown 先飞一次、doc 级 mousemove 连飞、mouseup 摘监听，
  shell 空白拖拽同款两段式）。信号纪律：view 内直读 camera/wm 信号是
  刻意的——小地图 DOM 极小，整体重渲染可接受，与世界层 transform 直写
  零重渲染策略相反（类注释留痕）。② shell.rb——HUD 接入 Minimap +
  `screen_viewport`（Opal 读 window / CRuby 固定值；与 `current_viewport`
  恒 nil 的 wm 钳制关闭语义分立）。③ CSS 入 zui_desktop.html（画布
  180×120 = Projector box，overflow hidden 裁剪越界取景框）。④ 单测
  +10 项（minimap_test 8：投影接线手算钉死/取景框任意缩放不出图/导航
  两段纯逻辑；shell_test +2 HUD 集成），`bundle exec rake` 双绿
  （minitest 61 项 + Opal 编译）。**待浏览器验收**：点击/拖拽手感、
  拖动中取景框跟手。
