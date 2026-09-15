# backtick_javascript: true
# frozen_string_literal: true

require_relative 'projector'

module Emerald
  module Zui
    # Z1 · 小地图：HUD 右下角的世界缩略 + 相机取景框（PLAN §8 防迷路三件套
    # 之一：世界窗口矩形投到固定像素盒，点击/拖拽 = 相机保持缩放飞到该世界点，
    # 靠它随时知道「自己在世界哪、窗口都在哪」）。导航数学全在 Projector，
    # 相机位移走 Camera#center_on，本组件只做投影接线与输入监听。
    #
    # 信号订阅纪律（与世界层刻意相反，PLAN §8）：view 内直接读 camera/wm
    # 信号——小地图 DOM 极小（窗块 + 取景框几十个 div），导航/开窗/拖窗时
    # 整体重渲染完全可接受；世界层的「transform 直写 DOM 零重渲染」是
    # 100000² 容器每帧重渲染即灾难的专属策略，这边不做那种优化。
    class Minimap < Citrine::Component
      # 地图画布像素盒（Projector 的 box；padding 在投影内扣除）
      BOX_W = 180
      BOX_H = 120
      PADDING = 8
      # CRuby（单测/SSR）下无真实窗口，视口取固定值；浏览器由 shell 注入
      # 读 window.inner* 的 provider，保持跟随 resize
      DEFAULT_VIEWPORT = { w: 1280, h: 800 }.freeze

      prop :wm       # Beryl::WindowManager（each_window 产 record，geom 是 Signal）
      prop :camera   # Emerald::Zui::Camera
      prop :viewport, default: -> { DEFAULT_VIEWPORT } # -> { w:, h: } 屏幕视口 provider

      # SSR/CRuby 不挂监听，钩子内部 defined?(Opal) 守卫，安全跳过
      on_mount :setup_minimap_input

      def view
        box(css_class: 'zui-minimap') do
          @canvas_node = box(css_class: 'zui-minimap-canvas') do
            each_window_blip
            box(css_class: 'zui-minimap-cam', style: camera_rect_style)
          end
        end
      end

      private

      # ── 投影接线（数学全在 Projector，此处只喂数据）──────

      def projector
        Projector.new(bounds: bounds, box: { w: BOX_W, h: BOX_H }, padding: PADDING)
      end

      # 世界包围盒：全部窗口矩形 ∪ 相机取景框——取景框永远落在图内，
      # 任何缩放下小地图都不空窗（防迷路的语义核心）
      def bounds
        rects = []
        wm.each_window { |r| rects << r.geom.get } # geom 是 Signal：开窗/拖窗自动重渲染
        rects << camera_world_rect
        Projector.union(rects)
      end

      # 相机在世界里的取景矩形（恒等式反推：屏幕 (0,0) ↔ 世界 (−x, −y)）
      def camera_world_rect
        cam = camera.get # 订阅相机：导航变化自动重渲染（刻意，见类注释）
        vp = current_viewport
        { x: -cam[:x], y: -cam[:y], w: vp[:w] / cam[:zoom], h: vp[:h] / cam[:zoom] }
      end

      def each_window_blip
        wm.each_window do |r|
          g = r.geom.get
          mx, my = projector.to_map(g[:x], g[:y])
          box(css_class: blip_class(r),
              style: { left: px(mx), top: px(my),
                       width: px(g[:w] * projector.scale),
                       height: px(g[:h] * projector.scale) })
        end
      end

      def blip_class(r)
        "zui-minimap-win#{' is-active' if wm.active?(r.id)}"
      end

      # 相机取景框样式：左上角 = 世界 (−x, −y) 的映射，边长 = 视口 ÷ zoom × s
      def camera_rect_style
        cam = camera.get
        mx, my = projector.to_map(-cam[:x], -cam[:y])
        s = projector.scale
        vp = current_viewport
        { left: px(mx), top: px(my),
          width: px(vp[:w] / cam[:zoom] * s), height: px(vp[:h] / cam[:zoom] * s) }
      end

      def current_viewport
        v = viewport
        v.respond_to?(:call) ? v.call : v
      end

      def px(n)
        "#{n.round(2)}px"
      end

      # ── 导航（点击/拖拽 = 相机保持缩放飞到该世界点，事件回调 → F6 安全区）

      # 纯逻辑段：地图坐标 → 世界坐标 → center_on（单测直钉这条）
      def fly_to_map_point(mx, my)
        wx, wy = projector.to_world(mx, my)
        camera.center_on(wx, wy, current_viewport)
      end

      # 客户端坐标（相对视口）减去画布原点 = 地图坐标；坐标系换算独立成段，
      # 浏览器侧拖动的每次 mousemove 都走这里
      def fly_to_client_point(client_x, client_y, origin)
        fly_to_map_point(client_x - origin[:left], client_y - origin[:top])
      end

      # 点击/拖拽监听挂画布（beryl setup_drag 两段式同款）：mousedown 先飞
      # 一次（点击 = 飞到该点），拖拽期间连续飞，松手摘监听。坐标经
      # getBoundingClientRect 归一到画布局部——命中窗块还是空白都一样
      def setup_minimap_input
        return unless defined?(Opal)

        canvas = @canvas_node.dom
        canvas.addEventListener('mousedown', ->(raw) { begin_map_nav(Native(raw), canvas) })
      end

      def begin_map_nav(ev, canvas)
        return if ev[:button] != 0

        ev.preventDefault
        doc = Native(`document`)
        origin = canvas.getBoundingClientRect
        fly_to_client_point(ev[:clientX], ev[:clientY], origin) # 按下即飞
        on_move = nil
        on_up = ->(_raw) {
          doc.removeEventListener('mousemove', on_move)
          doc.removeEventListener('mouseup', on_up)
        }
        on_move = ->(raw2) {
          e2 = Native(raw2)
          fly_to_client_point(e2[:clientX], e2[:clientY], origin)
        }
        doc.addEventListener('mousemove', on_move)
        doc.addEventListener('mouseup', on_up)
      end
    end
  end
end
