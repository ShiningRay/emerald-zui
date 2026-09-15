# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  module Zui
    # ZUI 桌面外壳（docs/PLAN.md §3.2/§3.3）：DesktopShell 的子类，把 view 拆成
    # 世界层（相机 transform 容器：壁纸/图标/窗口）+ HUD 层（屏幕固定：菜单栏/
    # 任务栏/托盘/Toast）；滚轮锚点缩放、空白拖拽平移在此接线，纯数学全在 Camera。
    # 经典模式 = 相机 {0,0,1} + viewport 钳制的退化形态（D4，Z2 模式开关接管）。
    #
    # 纪律：相机 signal 不在 view 内读（重渲染风暴，§8）——transform 由挂载时
    # 建的 Effect 直写 DOM（beryl setup_text_area 的 owned_effects 同款）；
    # 相机/wm 变更只从事件回调进入（beryl F6）。反引号 JS 仅在 Opal 守卫内。
    class Shell < Emerald::DesktopShell
      # 滚轮缩放灵敏度：factor = e^(-delta_y × 速率)（delta_y>0 缩小、<0 放大）
      WHEEL_ZOOM_SPEED = 0.001

      attr_reader :camera

      # 挂载后接线（在父类钩子之后）：相机 transform Effect + 舞台输入监听。
      # SSR/CRuby 不建 Effect，两个钩子内部 defined?(Opal) 守卫，安全跳过
      on_mount :setup_camera_effect, :setup_world_input

      def initialize
        @camera = Emerald::Zui::Camera.new
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
          end
        end
      end

      # HUD 层：屏幕固定、不随相机变换；各组件自身 fixed 定位，
      # .zui-hud 仅语义占位 + pointer-events 统筹（样式见 examples/zui_desktop.html）
      def hud_layer
        box(css_class: 'zui-hud') do
          menubar
          Beryl::Taskbar.new(wm: @wm).view
          tray
          toast_stack
        end
      end

      # ZUI 模式：无限画布没有「屏幕边缘」——视口恒 nil，wm 的 clamp_geom /
      # snap_zone 对 viewport 判空（beryl window.rb），一次关掉屏幕钳制与
      # 边缘吸附；resize 跟踪因此也保持 nil。classic 退化形态由 Z2 接管（D4）
      def current_viewport
        nil
      end

      private

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

      # 空白拖拽平移：mousedown 命中世界层空白（窗口面板/桌面图标不触发）→
      # 手势中直写 transform（零重渲染），松手 commit_pan 落点回写
      # （beryl setup_drag 同款两段式，PLAN §3.4）
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

      # 命中判定：目标自身或祖先命中窗口面板/桌面图标 → 不算世界空白
      def world_pan_target?(target)
        target && target.closest('.panel, .d-icon').nil?
      end

      # 松手落点回写：屏幕位移 ÷ zoom 进世界坐标（F6：仅事件回调内 set）
      def commit_pan(p)
        camera.pan_by(p[:dx], p[:dy])
      end
    end
  end
end
