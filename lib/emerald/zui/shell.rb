# backtick_javascript: true
# frozen_string_literal: true

# Clock 活图标 dogfood（PLAN §3.8）：register_builtin_apps 的注册对象。
# 经此静态引入后浏览器/CRuby 双端可用；入口 zui.rb 锁定期间 require 落
# 此处（与注册同路由，避免「类未加载致守卫跳过、dogfood 静默缺席」）
require_relative 'apps/clock'

module Emerald
  module Zui
    # ZUI 桌面外壳（docs/PLAN.md §3.2/§3.3）：DesktopShell 的子类，把 view 拆成
    # 世界层（相机 transform 容器：壁纸/图标/窗口）+ HUD 层（屏幕固定：菜单栏/
    # 任务栏/托盘/Toast）；滚轮锚点缩放、空白拖拽平移在此接线，纯数学全在 Camera。
    # 经典模式 = 相机 {0,0,1} + viewport 钳制的退化形态（D4，Z2 模式开关接管）。
    #
    # Z1.5 · 形态态机（B 方案，§3.8/§3.9）：窗口即图标——每实例 form ∈
    # {:window, :icon}，:icon 实例不渲染窗口本体（wm 只登记窗口形态），改在
    # 世界层渲染 live tile（inst.icon_view，同一实例的活跃视图）；窗口最小化
    # 按钮经形态切换缩成图标，双击 tile 涨回窗口（备份几何恢复）；切换的形变
    # 执行交 Morph.fly（幽灵期两端都不渲染，@morphing 守卫 + morph_tick 重渲染）。
    #
    # 纪律：相机 signal 不在 view 内读（重渲染风暴，§8）——transform 由挂载时
    # 建的 Effect 直写 DOM（beryl setup_text_area 的 owned_effects 同款）；
    # 相机/wm 变更只从事件回调进入（beryl F6）。反引号 JS 仅在 Opal 守卫内。
    class Shell < Emerald::DesktopShell
      # 滚轮缩放灵敏度：factor = e^(-delta_y × 速率)（delta_y>0 缩小、<0 放大）
      WHEEL_ZOOM_SPEED = 0.001
      # 应用启动去重窗（§8「双击图标双触发」守卫）：同应用无参重复 launch
      # 在该窗内合并为一次——机器级重复（双击双派发/监听器重复挂载，同 tick
      # 连发）被吞；人类有意再双击必在窗外
      LAUNCH_DEDUP_MS = 200
      # 相机飞行时长（CSS transition，examples/zui_desktop.html 的 .is-flying）
      FLIGHT_MS = 280
      # 聚焦单窗 / 全景的内边距（世界像素）
      FOCUS_PADDING = 80
      OVERVIEW_PADDING = 80

      # 图标形态 tile 的世界尺寸兜底（形变矩形对的 icon 端；正常路径取启动器
      # 实测矩形——见 assign_anchor 存下的 w/h，与桌面图标严丝合缝）
      ICON_TILE_W = 80
      ICON_TILE_H = 69

      attr_reader :camera

      # 形态切换收尾的重渲染信号：动画结束（transitionend/兜底/CRuby 同步）
      # 只摘 @morphing 普通 ivar，不触发任何订阅——显式 bump 本 signal 让
      # 被守卫压着的渲染循环重跑（读即订阅，见 each_icon_form_tile）
      state :morph_tick, default: 0

      # 挂载后接线（在父类钩子之后）：相机 transform Effect + 舞台输入监听。
      # SSR/CRuby 不建 Effect，两个钩子内部 defined?(Opal) 守卫，安全跳过
      on_mount :setup_camera_effect, :setup_world_input

      def initialize
        @camera = Emerald::Zui::Camera.new
        # 形变动画期重入守卫（§3.9）：win_id => true。动画两端（窗口/tile）
        # 都不渲染，只有幽灵；close_window 负责中途注销的清理（dispose 语义）
        @morphing = {}
        # 启动去重窗的最近启动记录：app_id(Symbol) => [now_ms, win_id]
        @launch_seen = {}
        super
      end

      # ── 视图组装（PLAN §3.2）：stage（屏幕固定）→ 世界（相机容器）→ HUD

      def view
        stage_layer
        hud_layer
      end

      # 舞台层：屏幕固定、不随相机变换。手势（滚轮/拖拽平移）与视觉底层
      # （壁纸背景）都挂在这里——世界容器只有 100000²，越出它的区域
      # （如平移到负世界坐标方向）若没有 stage 兜底，滚轮/拖拽会落在
      # body 上无监听、颜色露 body 底色（Z0 验收实测 bug，本层即修复）；
      # 壁纸不再渲染世界内壁纸盒，改由 .zui-stage 的 CSS 背景承载
      # （var(--wallpaper)，主题切换继续生效），世界内外颜色天然一致。
      # @stage_node 挂监听；@world_node 挂相机 transform（两个挂载钩子用）
      def stage_layer
        @stage_node = box(css_class: 'zui-stage') do
          @world_node = box(css_class: 'zui-world') do
            icon_grid
            each_window_frame
            each_icon_form_tile
          end
        end
      end

      # ── 表征互斥的图标网格（PLAN §3.8 修订 2026-09-16）───────
      #
      # 同一对象任意时刻只有一个表征在场上：应用有实例时其启动器图标让位
      # （槽位交给实例的图标形态；窗口形态时槽位是空的——图标"变成"窗口
      # 飞走了）。修正前启动器与实例 tile 并存 = 一个应用两个图标（用户
      # 复查指出的缺陷）
      def icon_grid
        morph_tick # 读即订阅：实例增删（launch/quit）后启动器让位/回归
        box(css_class: 'icon-grid') do
          @registry.apps.each do |app|
            app_icon(app) unless app_has_instances?(app[:id])
          end
          desktop_entries.each { |node| file_icon(node) }
        end
      end

      # 该应用是否有存活实例（任意形态）——启动器让位判定
      def app_has_instances?(app_id)
        @registry.each_running.any? { |inst| inst.class.app_id == app_id.to_sym }
      end

      # 每应用启动器挂钩类：d-icon-app-<app_id> 供启动形变测量槽位（§3.9 形变
      # 源元素）与测试查询；sanitize 与 win_frame_class 同规则
      def launcher_class(key)
        base = icon_tile_class(key) # 父类：含选中态后缀
        return base unless key.start_with?('app:')

        base.sub('d-icon', "d-icon d-icon-app-#{sanitize_win_id(key.delete_prefix('app:'))}")
      end

      def app_icon(app)
        key = "app:#{app[:id]}"
        icon_tile(key, glyph: app[:icon].to_s, name: app[:title].to_s,
                  on_open: -> { launch_app(app[:id]) })
      end

      # 与父类同构的图标块，唯 css_class 走 launcher_class（挂钩类）
      def icon_tile(key, glyph:, name:, on_open:)
        box(css_class: launcher_class(key),
            on_click: ->(_e) { self.selected_icons = [key] },
            on_dblclick: on_open) do
          box(css_class: 'd-icon-glyph') { glyph }
          label(css_class: 'd-icon-name') { name }
        end
      end

      # 窗口渲染循环（PLAN §3.8 form 分派）：:window 形态走窗口框原路径
      # （window_frame 与 wm.frame 同款接线，唯 on_minimize 改接形态切换）；
      # :icon 形态不渲染窗口本体（wm 只登记窗口形态实例），其 live tile 见
      # each_icon_form_tile。D4 守卫保留 wm.windows 成员判定 + form 分派 +
      # 形变期跳窗（动画两端都不渲染，§3.9）
      def each_window_frame
        wins = @wm.windows
        @registry.each_running do |inst|
          next unless inst.form == :window
          next unless wins.include?(inst.win_id)
          next if morphing?(inst.win_id)

          window_frame(inst).view
        end
        nil
      end

      # 图标形态渲染分发（PLAN §3.8）：:icon 实例在世界层渲染 live tile——
      # absolute 于驻留几何（世界坐标，D2），内容 = inst.icon_view（同一实例
      # 同一批 state signal 的活跃视图：覆写即活图标，天然实时）。单击选中、
      # 双击涨回窗口、可拖拽换位（运行中应用的图标拖换位顺带交付，静态启动
      # 器不受益）。形变期不渲染（@morphing 守卫），收尾由 morph_tick 触发
      def each_icon_form_tile
        morph_tick # 读即订阅：形态切换收尾后重跑本循环
        @registry.each_running do |inst|
          next unless inst.form == :icon
          next if morphing?(inst.win_id)

          g = ensure_icon_geometry(inst)
          box(css_class: icon_form_class(inst), style: icon_form_style(g),
              on_mouse_down: ->(ev) { begin_icon_form_drag(ev, inst) },
              on_click: ->(_ev) { select_icon_form(inst) unless @icon_drag_moved },
              on_dblclick: ->(_ev) { morph_to_window(inst) unless @icon_drag_moved }) do
            inst.icon_view
          end
        end
        nil
      end

      # HUD 层：屏幕固定、不随相机变换；各组件自身 fixed 定位，
      # .zui-hud 仅语义占位 + pointer-events 统筹（样式见 examples/zui_desktop.html）。
      # 小地图殿后：世界缩略 + 相机取景框，点击/拖拽 = 相机飞到该世界点
      # （PLAN §8 防迷路；其内部读 camera/wm 信号是刻意的，见 Minimap 类注释）
      def hud_layer
        box(css_class: 'zui-hud') do
          menubar
          Beryl::Taskbar.new(wm: taskbar_bridge).view
          tray
          # 必须经 render(类) 挂载：.new(...).view 内联渲染不走 render_component，
          # on_mount 钩子不触发（citrine renderer.rb），小地图的画布监听永远挂不上
          # （浏览器实证：点击/拖拽导航失效、canvas 零监听）
          render(Emerald::Zui::Minimap, wm: @wm, camera: @camera,
                 viewport: -> { screen_viewport })
          toast_stack
        end
      end

      # ZUI 模式：无限画布没有「屏幕边缘」——视口恒 nil，wm 的 clamp_geom /
      # snap_zone 对 viewport 判空（beryl window.rb），一次关掉屏幕钳制与
      # 边缘吸附；resize 跟踪因此也保持 nil。classic 退化形态由 Z2 接管（D4）
      def current_viewport
        nil
      end

      # ── 形态切换（PLAN §3.8 态机的 shell 执行段；事件回调入口，F6 安全区）──

      # 窗口 → 图标：备份窗口几何（实例侧 morph_to）→ 首缩起分配驻留位 →
      # 摘窗（wm 只登记窗口形态实例；实例留 registry——与 close 销毁语义
      # 分立，deactivate 不触发）→ 窗口矩形 ⇒ 图标矩形的形变交 Morph.fly
      # （§3.9 幽灵期两端都不渲染）。最小化按钮的 ZUI 语义即本方法（beryl
      # 任务栏最小化按钮暂走经典 toggle_min，HUD 在 transform 外，§3.9）
      def morph_to_icon(inst)
        return if morphing?(inst.win_id) || inst.form != :window

        g = @wm.geometry(inst.win_id)
        return unless g

        ensure_icon_geometry(inst, base: g)
        inst.morph_to(:icon, window_geometry: g)
        @morphing[inst.win_id] = true
        fly_morph(inst, from: g, to: icon_form_rect(inst),
                  from_class: "zui-win-#{sanitize_win_id(inst.win_id)}")
        @wm.close(inst.win_id)
        inst
      end

      # 图标 → 窗口：位置**由图标锚位决定**（§3.8 修订②：窗口从图标的当前
      # 位置长出——图标拖到哪，双击后窗口就在哪出现，形变是原地放大），尺寸
      # 取窗口备份/默认（窗口大小语义与图标位置解耦）→ flip form → wm.open
      # 重登记 → 幽灵原地放大。双击 tile 与「图标形态单例再启动」两路进入
      def morph_to_window(inst)
        return if morphing?(inst.win_id) || inst.form != :icon

        from = icon_form_rect(inst)
        restored = inst.morph_to(:window)
        to = window_rect_for(inst, restored)
        @morphing[inst.win_id] = true
        fly_morph(inst, from: from, to: to,
                  from_class: "zui-iconform-#{sanitize_win_id(inst.win_id)}")
        @wm.open(inst.win_id, title: inst.class.app_title, geometry: to)
        inst
      end

      # 窗口形态的世界矩形（形变矩形对的 window 端）：位置 = 图标锚位，
      # 尺寸 = 备份几何 / 默认级联；radius = panel 圆角（幽灵 border-radius
      # 随之形变，morph.rb to_rect[:radius] 契约的可选键）
      def window_rect_for(inst, restored)
        anchor = inst.icon_geometry || FALLBACK_GEOMETRY
        base = restored || geometry_for(inst)
        { x: anchor[:x], y: anchor[:y], w: base[:w], h: base[:h], radius: 10 }
      end

      # 图标拖移的落点回写（纯逻辑段，单测直钉）：世界坐标直写驻留几何——
      # tile 的 left/top 即世界坐标，与相机缩放无关（D2：布局坐标不受
      # transform 影响）。一经写回即永驻，下次缩起落回此处（§3.8 可拖拽驻留）
      def place_icon_at(payload)
        payload[:inst].icon_geometry = { x: payload[:x], y: payload[:y] }
      end

      # ── 应用启动 / 关闭（覆写父类链路，Z1.5 增补）────────

      # 内置应用注册：父类注册 emerald 内置（About/Files/...）后追加 ZUI 侧
      # ——Clock 活图标 dogfood（PLAN §3.8，契约：Emerald::Zui::Apps::Clock /
      # app_id :clock / app_title '时钟'）。按可用性注册：类未落地（并行路线
      # 实现中）时 const_defined? 守卫跳过，与父类桩期语义一致；注册冲突
      # （重复 id / 未声明 app_id）不阻塞外壳启动
      def register_builtin_apps
        super
        return unless defined?(Emerald::Zui::Apps) &&
                      Emerald::Zui::Apps.const_defined?(:Clock, false)

        # 显式 const_get（与守卫同口径）：注册的是「查到的类」，单测可钉
        @registry.register(Emerald::Zui::Apps.const_get(:Clock, false))
      rescue ArgumentError
        nil
      end

      # 启动应用（§3.8 修订：**字面意义的"图标变成窗口"**）：
      # ① 去重守卫（§8「双击图标双触发」）——同应用无参 launch 在
      #    LAUNCH_DEDUP_MS 窗内合并；
      # ② 单例图标形态再启动 = 涨回窗口（morph 恢复备份几何）；
      # ③ 建实例 → 锚位取**启动器槽位** → form 先置 :window（启动器随之让位，
      #    表征互斥）→ 幽灵从图标矩形飞涨到窗口矩形 → 收尾 wm.open 出窗。
      # CRuby/无槽位 → 直接开窗（Morph 契约与槽位测量的兜底路径）
      def launch_app(id, **argv)
        return super if argv.any?

        key = id.to_sym
        now = now_ms
        if (iconic = singleton_icon_form(key))
          morph_to_window(iconic)
          @launch_seen[key] = [now, iconic.win_id]
          return iconic
        end

        seen = @launch_seen[key]
        if seen && now - seen.first < LAUNCH_DEDUP_MS &&
           (live = @registry.instance(seen.last))
          restore_or_focus(live)
          return live
        end

        inst = @registry.launch(key) # 只建实例（父类 D3/R2 语义）
        @launch_seen[key] = [now, inst.win_id]
        if @wm.windows.include?(inst.win_id) # 单例命中：已有窗，聚焦即可
          inst.form = :window
          @wm.focus(inst.win_id)
          return inst
        end

        open_with_morph(inst)
        inst
      end

      # 带形变的开窗：锚位 → form :window → bump morph_tick（启动器让位 +
      # 形变期两端都不渲染，只有幽灵）→ 幽灵从图标矩形飞涨到窗口矩形 →
      # wm.open（渲染仍被 @morphing 压着）→ 收尾 finish_morph 出窗
      def open_with_morph(inst)
        assign_anchor(inst)
        inst.form = :window
        # 位置 = 图标锚位（启动方向同样"在图标处长出"）；尺寸取默认级联
        g = window_rect_for(inst, nil)
        slot = launcher_rect_for(inst.class.app_id)
        self.morph_tick = morph_tick + 1
        if slot
          @morphing[inst.win_id] = true
          fly_morph(inst, from: slot.merge(radius: 10), to: g,
                    from_class: "d-icon-app-#{sanitize_win_id(inst.class.app_id)}")
        end
        @wm.open(inst.win_id, title: inst.class.app_title, geometry: g)
        inst
      end

      # 锚位（§3.8 槽位恒定不变量：图标在哪，窗口就从哪长出、缩回哪去）：
      # 首个实例取**启动器槽位**（DOM 实测世界矩形）；同应用已有实例或槽位
      # 不可测 → 级联兜底。锚位一经确定即永驻（可拖拽换位）
      def assign_anchor(inst)
        return if inst.icon_geometry

        slot = launcher_rect_for(inst.class.app_id)
        seq = @registry.each_running.count do |other|
          !other.equal?(inst) && other.class.app_id == inst.class.app_id
        end
        if slot && seq.zero?
          # 记全矩形（含实测宽高）：tile 尺寸与形变落点都用它——缩回后与
          # 桌面图标严丝合缝，不留「88×88 深色卡片」那种跳变
          inst.icon_geometry = { x: slot[:x], y: slot[:y], w: slot[:w], h: slot[:h] }
        else
          inst.icon_geometry = AppForm.icon_slot(slot || FALLBACK_GEOMETRY, seq)
        end
      end

      # 启动器槽位的世界矩形（DOM 实测：图标与世界容器 rect 之差 ÷ zoom——
      # 两个 rect 都在屏幕空间，相减即世界位移的屏幕投影，天然免疫相机
      # transform）。CRuby 无 DOM → nil（形变与槽位退化为级联兜底）。
      # ⚠️ 选择器一律走 Ruby 字符串 → Native 方法传参：**不要**把 `#{...}`
      # 写进 backtick JS 的字符串字面量里（Opal 下插值不求值，实参变字面
      # "sel"，querySelector 落空——本方法浏览器实证踩坑）
      def launcher_rect_for(app_id)
        return nil unless defined?(Opal)

        sel = ".icon-grid .d-icon-app-#{sanitize_win_id(app_id)}"
        doc = Native(`document`)
        el = doc.querySelector(sel)
        world = @world_node.dom
        return nil if el.nil? || world.nil?

        a = el.getBoundingClientRect
        b = world.getBoundingClientRect
        z = camera.get[:zoom]
        { x: (a[:left] - b[:left]) / z, y: (a[:top] - b[:top]) / z,
          w: a[:width] / z, h: a[:height] / z }
      end

      # 命中已有实例时的复用：图标形态 → 涨回窗口；窗口形态 → 聚焦
      def restore_or_focus(inst)
        if inst.form == :icon
          morph_to_window(inst)
        elsif @wm.windows.include?(inst.win_id)
          @wm.focus(inst.win_id)
        end
      end

      # 关闭链路（ZUI 修订 2026-09-16）：✕ / ⌘W = **收起为图标**（形变缩小
      # 还原为图标，实例留在 registry）——用户定调「关闭/最小化都是窗口
      # 变形还原为图标」。真正的退出走 quit_app（⌘Q / 菜单栏「退出当前
      # 应用」）。图标形态实例无 wm 记录（close_active_window 取 wm 序，
      # 天然不可达）
      def close_window(win_id)
        inst = @registry.instance(win_id)
        return super unless inst && inst.form == :window

        morph_to_icon(inst)
      end

      # 退出应用（真销毁，D3 close 语义）：窗口态与收起态都可退。摘形变
      # 守卫/去重记录 → 窗口形态先摘窗 → dispose → 启动器回归（icon_grid
      # 的表征互斥判定订阅 morph_tick）
      def quit_app(win_id)
        inst = @registry.instance(win_id)
        return unless inst

        @morphing.delete(win_id)
        @launch_seen.delete(inst.class.app_id)
        @wm.close(win_id) if inst.form == :window
        @registry.dispose(win_id)
        self.morph_tick = morph_tick + 1
        nil
      end

      # ⌘Q / 菜单入口：优先活动窗口，无窗则退最近收起的图标形态实例
      def quit_active_app
        top = @wm.windows.last
        return quit_app(top) if top

        iconic = @registry.each_running.to_a.reverse.find { |inst| inst.form == :icon }
        quit_app(iconic.win_id) if iconic
      end

      # 全局快捷键：父类（⌘W 收起、⌘1..9 聚焦）之上追加 ⌘Q = 退出应用——
      # ZUI 下 ✕/⌘W 只收起，退出必须另有出口（用户拍板：⌘Q + 菜单项）
      def register_global_hotkeys
        super
        Emerald.hotkey.register('meta+q') { quit_active_app }
        Emerald.hotkey.register('meta+0') { overview }
      end

      # 纯修饰键 keydown 不进 chord 解析：浏览器把单独按下的 ⌘/Shift/Alt 也
      # 当 keydown 派发，emerald hotkey 的 chord 解析对 "meta+Meta" 会 raise
      # （⌘Q 实测报错，不致命但有噪声）。根因属 emerald hotkey.rb，反哺候选
      def dispatch_hotkey(ev)
        return if %w[Meta Shift Alt Control CapsLock].include?(ev.key)

        super
      end

      # 菜单栏：父类「应用/桌面」之上，在「应用」菜单尾部补「退出当前应用」
      # （⌘Q 的可发现性入口；多实例再开一个入口也在同一菜单的启动项里）
      def menubar_data
        data = super
        apps = data.find { |menu| menu[:label] == '应用' }
        if apps
          apps[:items] = apps[:items] + [{ separator: true },
                                         { label: '退出当前应用 ⌘Q',
                                           action: -> { quit_active_app } }]
        end
        data
      end

      # ── 导航：相机飞行 / 全景 / 任务栏改道（PLAN §3.4，Z1）────────

      # 相机飞行：给世界层挂 CSS transition 后再改相机，浏览器补间到位
      #（CRuby 无 DOM：直接改相机，单测断言结果）。改相机前强制 reflow，
      # 否则同一帧里「加 transition + 改 transform」会被合并成一次计算、
      # 不产生过渡（浏览器实现细节，实测经验）
      def with_flight
        unless defined?(Opal)
          yield
          return
        end

        el = @world_node.dom
        el.classList.add('is-flying')
        el.offsetWidth # 强制 reflow：让 transition 先生效
        yield
        Beryl::Timer.after(FLIGHT_MS + 60) { el.classList.remove('is-flying') }
      end

      # 飞到世界矩形（fit + 内边距）
      def fly_camera_to(rect, padding: FOCUS_PADDING)
        with_flight { camera.fit(rect, screen_viewport, padding: padding) }
        nil
      end

      # ⌘0 全景：所有窗口 + 图标形态实例入视野（防迷路的兜底出口，§8）；
      # 空桌面回原点（home）
      def overview
        # beryl 的 each_window 是块式且显式返回 nil（R5：空表不外泄 "[]"），
        # 不能当 Enumerable 用——手工收集
        rects = []
        @wm.each_window do |rec|
          g = @wm.geometry(rec.id)
          rects << g if g
        end
        @registry.each_running.each do |inst|
          next unless inst.form == :icon && inst.icon_geometry

          rects << icon_form_rect(inst).slice(:x, :y, :w, :h)
        end

        if rects.empty?
          with_flight { camera.home }
        else
          fly_camera_to(Projector.union(rects), padding: OVERVIEW_PADDING)
        end
        nil
      end

      # 任务栏「最小化」（点激活窗）：与 ✕ 同语义 = 收起为图标（§3.8）
      def collapse_window(win_id)
        inst = @registry.instance(win_id)
        if inst && inst.form == :window
          morph_to_icon(inst)
        else
          @wm.toggle_min(win_id)
        end
        nil
      end

      # 任务栏「切到该窗」（点后台/最小化窗）：聚焦 + 相机飞行到该窗
      def focus_window_with_flight(win_id)
        @wm.focus(win_id)
        g = @wm.geometry(win_id)
        fly_camera_to(g, padding: FOCUS_PADDING) if g
        nil
      end

      # 任务栏桥接（hud_layer 的 Beryl::Taskbar 消费）
      def taskbar_bridge
        @taskbar_bridge ||= TaskbarBridge.new(wm: @wm, shell: self)
      end

      private

      # ── 窗口框直连（PLAN §3.8 最小化语义的关键接线）──────────

      # 窗口框直连（替代 Beryl::WindowManager#frame 的便捷接线）：beryl 把
      # on_minimize 硬接到 toggle_min，而 ZUI 语义里「最小化」= 缩成图标
      # （§3.8「最小化按钮触发」）——此处完整复刻 wm.frame 的接线（几何 /
      # z 序 / 激活态 / 拖移缩放落点 / 双击最大化 / 关闭链路），只换
      # on_minimize → morph_to_icon。window_opts 透传语义不变：snap 默认开，
      # closable / minimizable / maximizable 默认 true，css_class 由 shell
      # 挂钩类统一生成（win_frame_class，含应用自声明）
      def window_frame(inst)
        id = inst.win_id
        opts = inst.class.window_opts.dup
        snap = opts.delete(:snap) { true }
        flags = {
          closable: opts.delete(:closable) { true },
          minimizable: opts.delete(:minimizable) { true },
          maximizable: opts.delete(:maximizable) { true },
        }
        opts.delete(:css_class)
        g = @wm.geometry(id)
        Beryl::WindowFrame.new(
          title: @wm.record(id).title,
          geometry: { 'px' => g[:x], 'py' => g[:y], 'pw' => g[:w], 'ph' => g[:h] },
          z_index: @wm.z(id),
          active: @wm.active?(id),
          minimized: @wm.minimized?(id),
          maximized: @wm.maximized?(id),
          min_w: @wm.record(id).min_w, min_h: @wm.record(id).min_h,
          content: -> { inst.view },
          on_front: ->(_el) { @wm.focus(id) },
          on_move: ->(ev) { @wm.place(id, ev, snap: snap) },
          on_resize: ->(ev) { @wm.place(id, ev) },
          # D3 定案：ZUI 下「最大化」= 让该窗充满视野（相机 fit）——wm 的
          # toggle_max 依赖视口几何（§3.3 viewport 恒 nil），在此语义下不适用
          on_head_dblclick: ->(_ev) { fly_camera_to(@wm.geometry(id)) },
          on_minimize: -> { morph_to_icon(inst) },
          on_maximize: -> { fly_camera_to(@wm.geometry(id)) },
          on_close: -> { close_window(id) },
          css_class: win_frame_class(inst),
          **flags, **opts
        )
      end

      # ── 形态切换内部段 ─────────────────────────────────────

      # 形变执行段（§3.9）：源元素（幽灵克隆底本）按挂钩类在世界层内查询
      # （窗口面板 zui-win-<id> / 图标 tile zui-iconform-<id>）；CRuby 无
      # DOM，Morph.fly 直接回调 on_done（Morph 契约的测试友好兜底）
      def fly_morph(inst, from:, to:, from_class:)
        if defined?(Opal)
          el = Native(`document`).querySelector(".zui-world .#{from_class}")
          Morph.fly(@world_node.dom, el, from, to, -> { finish_morph(inst) })
        else
          Morph.fly(nil, nil, from, to, -> { finish_morph(inst) })
        end
      end

      # 形变收尾（transitionend / 兜底定时器，CRuby 为同步回调）：摘重入
      # 守卫 + bump morph_tick 触发重渲染——目标端在动画期被 @morphing
      # 压着不渲染，到此才出现
      def finish_morph(inst)
        @morphing.delete(inst.win_id)
        self.morph_tick = morph_tick + 1
      end

      def morphing?(win_id)
        @morphing.key?(win_id)
      end

      # 驻留几何缺省分配（PLAN §3.8「图标几何，可拖拽驻留」）：首次缩起以
      # 窗口位置为基点，按当时已驻留图标数级联错开（AppForm.icon_slot 纯
      # 函数）——同位叠死的多个窗口各得其所。一经驻留不覆盖：用户拖过位
      # 就永驻该位，下次缩起落回此处
      def ensure_icon_geometry(inst, base: nil)
        return inst.icon_geometry if inst.icon_geometry

        base ||= @wm.geometry(inst.win_id) || FALLBACK_GEOMETRY
        seq = @registry.each_running.count { |o| !o.equal?(inst) && o.form == :icon }
        inst.icon_geometry = AppForm.icon_slot(base, seq)
      end

      # 图标形态 tile 的世界矩形（形变矩形对的 icon 端）：位置与尺寸取锚位
      # 实测值（启动时从启动器量得，见 assign_anchor），缺尺寸时退兜底常量；
      # radius 取桌面图标圆角（10，= .d-icon 的 var(--radius)）
      def icon_form_rect(inst)
        g = inst.icon_geometry || FALLBACK_GEOMETRY
        { x: g[:x], y: g[:y], w: g[:w] || ICON_TILE_W, h: g[:h] || ICON_TILE_H, radius: 10 }
      end

      # ── 图标 tile 内部段 ───────────────────────────────────

      # tile 挂钩类（跨路线契约）：zui-iconform zui-iconform-<sanitized id> 在
      # 前，**共用 .d-icon 视觉**（与启动器同款：透明底/圆角/hover/选中态）；
      # sanitize 规则与 win_frame_class / minimap.rb 的 querySelector 一致；
      # is-selected 为单击选中态（与启动器同款状态类）
      def icon_form_class(inst)
        cls = "zui-iconform d-icon zui-iconform-#{sanitize_win_id(inst.win_id)}"
        cls += ' is-selected' if selected_icons.include?("iconform:#{inst.win_id}")
        cls
      end

      # tile 世界定位 + 观感：**与桌面启动器图标同款**——复用 `.d-icon` 的
      # 视觉（透明底、无边框、无投影、圆角 var(--radius)、hover/选中态），
      # 尺寸取锚位实测值（与启动器一致）。位置/尺寸是布局量（世界坐标），
      # 相机 transform 只改视觉不改布局（§3.1 恒等式前提）。
      # z_index 必须 > .icon-grid 的 1（emerald 页面壳给图标网格设了 z-index: 1）：
      # tile 常驻启动器槽位、与网格同区重叠——不抬层就被网格盖住、点击全被
      # 网格接走（双击涨回失效，浏览器实证踩坑）
      def icon_form_style(g)
        { position: 'absolute',
          left: "#{g[:x]}px", top: "#{g[:y]}px",
          width: "#{g[:w] || ICON_TILE_W}px", height: "#{g[:h] || ICON_TILE_H}px",
          z_index: 2,
          cursor: 'pointer' }
      end

      def select_icon_form(inst)
        self.selected_icons = ["iconform:#{inst.win_id}"]
      end

      # 图标拖换位（世界层内手势，beryl setup_drag / 空白平移同款两段式）：
      # 手势中直写 tile 的 left/top（世界坐标：屏幕位移 ÷ zoom——D2 布局
      # 坐标不受相机 transform 影响），松手经 place_icon_at 落点回写
      # （事件回调 → F6）。3px 死区内不算拖拽，单击选中/双击涨回不受影响；
      # 拖过则抑制随后的 click/dblclick。CRuby 无 DOM，整体跳过
      def begin_icon_form_drag(ev, inst)
        return unless defined?(Opal)
        return if ev.raw[:button] != 0

        ev.prevent_default
        ev.stop_propagation # 不冒泡到 stage——空白平移监听在祖先层
        doc = Native(`document`)
        tile = ev.raw[:currentTarget]
        sx = ev.raw[:clientX]
        sy = ev.raw[:clientY]
        start = icon_form_rect(inst)
        cur_x = start[:x]
        cur_y = start[:y]
        moved = false
        @icon_drag_moved = false
        on_move = nil
        on_up = ->(_raw) {
          doc.removeEventListener('mousemove', on_move)
          doc.removeEventListener('mouseup', on_up)
          handle_event(:place_icon_at, { inst: inst, x: cur_x, y: cur_y }) if moved
        }
        on_move = ->(raw2) {
          e2 = Native(raw2)
          ldx = e2[:clientX] - sx
          ldy = e2[:clientY] - sy
          next if !moved && ldx.abs < 3 && ldy.abs < 3

          moved = true
          @icon_drag_moved = true # 抑制拖拽松手后的 click（选中）/ dblclick（涨回）
          zoom = camera.get[:zoom]
          cur_x = start[:x] + ldx.to_f / zoom
          cur_y = start[:y] + ldy.to_f / zoom
          tile[:style][:left] = "#{cur_x}px"
          tile[:style][:top] = "#{cur_y}px"
        }
        doc.addEventListener('mousemove', on_move)
        doc.addEventListener('mouseup', on_up)
      end

      # ── 启动去重内部段 ─────────────────────────────────────

      # 图标形态的单例实例（再启动 = 涨回窗口的执行对象）；多实例应用的
      # 图标形态不受理——启动器语义就是开新实例
      def singleton_icon_form(key)
        @registry.each_running.find do |inst|
          inst.form == :icon && inst.class.singleton && inst.class.app_id == key
        end
      end

      # 毫秒时钟（去重窗用）：CRuby/Opal 同一实现（Time#to_f 两侧都有），
      # 单测经 stub 钉时间线
      def now_ms
        (Time.now.to_f * 1000).round
      end

      # ── 挂钩类与视口 ──────────────────────────────────────

      # id 消毒：win_id 含 '#'（多实例 about#2）等 CSS 特殊字符时，挂钩类
      # 与 querySelector 双侧同步替换——规则必须与 minimap.rb 的缩略图
      # 查询一致，改一处另一处必须跟（shell_test 挂钩断言 + 形变源元素
      # 查询依赖它）
      def sanitize_win_id(id)
        id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')
      end

      # 每窗挂钩类：zui-win-<sanitized id> 在前，应用自声明的 window_opts
      # css_class 在后（window_opts 可能已带，如 stickynote 异形窗的
      # sticky-note-win）
      def win_frame_class(inst)
        "zui-win-#{sanitize_win_id(inst.win_id)} #{inst.class.window_opts[:css_class]}".strip
      end

      # 屏幕视口真实尺寸（导航数学用：center_on / 小地图取景框）：ZUI 覆写
      # current_viewport 恒 nil 是为了关 wm 钳制/吸附（§3.3），而相机居中与
      # 取景框换算恰恰需要真值——Opal 读 window，CRuby 固定值（父类实现同款）
      def screen_viewport
        defined?(Opal) ? { w: `window.innerWidth`, h: `window.innerHeight` } : { w: 1280, h: 800 }
      end

      # ── 相机接线（PLAN §3.2）────────────────────────────

      # transform 直写：订阅 camera signal，把 {x,y,zoom} 写成世界层内联
      # transform——相机变更只动 style，不触发整层重渲染；Effect 归节点
      # owned_effects，卸载即释放（beryl setup_text_area 同款模式）
      def setup_camera_effect
        return unless defined?(Opal)

        node = @world_node
        el = node.dom
        node.owned_effects << Citrine::Effect.create {
          el[:style][:transform] = camera_transform(camera.get)
        }
      end

      # 相机状态 → CSS transform（origin 0 0，PLAN §3.1 恒等式：
      # screen = (world + {x,y}) × zoom → translate(x·z, y·z) scale(z)）
      def camera_transform(state)
        z = state[:zoom]
        "translate(#{state[:x] * z}px, #{state[:y] * z}px) scale(#{z})"
      end

      # ── 输入接线（PLAN §3.4，浏览器侧适配层）──────────────

      # 世界层输入：滚轮锚点缩放 + 空白拖拽平移，监听挂在**舞台层**而非世界
      # 容器（stage 屏幕固定满视野——世界外的负坐标区域同样可交互，见
      # stage_layer 注释）。不用 beryl L1 wheel 原语——它的 payload 只有
      # {delta_x, delta_y}，锚点缩放需要指针坐标（clientX/Y）
      def setup_world_input
        return unless defined?(Opal)

        el = @stage_node.dom
        el.addEventListener('wheel', ->(raw) { on_world_wheel(Native(raw)) })
        el.addEventListener('mousedown', ->(raw) { begin_world_pan(Native(raw)) })
      end

      # 滚轮：以指针为锚缩放（事件回调 → F6 安全区）
      def on_world_wheel(ev)
        ev.preventDefault
        handle_event(:zoom_at_point, { x: ev[:clientX], y: ev[:clientY], delta_y: ev[:deltaY] })
      end

      def zoom_at_point(p)
        camera.zoom_at(p[:x], p[:y], wheel_factor(p[:delta_y]))
      end

      def wheel_factor(delta_y)
        Math.exp(-delta_y * WHEEL_ZOOM_SPEED)
      end

      # 空白拖拽平移：mousedown 命中世界层空白（窗口面板/桌面图标/图标形态
      # tile 不触发）→ 手势中直写 transform（零重渲染），松手 commit_pan
      # 落点回写（beryl setup_drag 同款两段式，PLAN §3.4）
      def begin_world_pan(ev)
        return if ev[:button] != 0
        return unless world_pan_target?(ev[:target])

        ev.preventDefault
        stage = @stage_node.dom
        world = @world_node.dom
        doc = Native(`document`)
        sx = ev[:clientX]
        sy = ev[:clientY]
        base = camera.get
        stage.classList.add('is-panning')
        ldx = 0
        ldy = 0
        on_move = nil
        on_up = ->(_raw) {
          doc.removeEventListener('mousemove', on_move)
          doc.removeEventListener('mouseup', on_up)
          stage.classList.remove('is-panning')
          handle_event(:commit_pan, { dx: ldx, dy: ldy })
        }
        on_move = ->(raw2) {
          e2 = Native(raw2)
          ldx = e2[:clientX] - sx
          ldy = e2[:clientY] - sy
          # 手势跟随：抓取语义——内容随光标同向移动（与 pan_by 同式加号），
          # 直写 style 不进 signal——松手才落点回写
          world[:style][:transform] = camera_transform(
            x: base[:x] + ldx / base[:zoom],
            y: base[:y] + ldy / base[:zoom],
            zoom: base[:zoom]
          )
        }
        doc.addEventListener('mousemove', on_move)
        doc.addEventListener('mouseup', on_up)
      end

      # 命中判定：目标自身或祖先命中窗口面板/桌面图标/图标形态 tile →
      # 不算世界空白（tile 的 mousedown 另有拖拽监听并 stopPropagation，
      # 此处为双保险）
      def world_pan_target?(target)
        target && target.closest('.panel, .d-icon, .zui-iconform').nil?
      end

      # 松手落点回写：屏幕位移 ÷ zoom 进世界坐标（F6：仅事件回调内 set）
      def commit_pan(p)
        camera.pan_by(p[:dx], p[:dy])
      end
    end
  end
end
