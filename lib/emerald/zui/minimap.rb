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
    #
    # 迭代增补（用户验收反馈，2026-09-15）：
    # · 拖拽「呼吸」修复——bounds 恒含取景框，拖拽飞行中取景框移动 → 包围盒变
    #   → 比例尺重拟合 → 光标下的世界点持续漂移（实测手感错乱）。mousedown
    #   冻结当时显示层的 Projector 快照到 @drag_projector（普通 ivar 非 signal：
    #   view 本就因 camera 变化重跑，重跑时读它即可，无需额外响应化），显示层
    #   与坐标换算全程走快照：小地图视觉完全静止，只有取景框在静态地图上平移；
    #   mouseup 清空，松手恢复动态拟合（shell 空白拖拽落点回写同款两段式）。
    # · 内容缩略图——真实窗口面板 cloneNode 进锚点盒（命令式填充，见
    #   setup_minimap_thumbs），不是色块；色块仍渲染（底层兜底 + CRuby/SSR）。
    # · 回家钮——面板右上角 ⌂，一键 camera.home（相机回 {0,0,1}）。
    class Minimap < Citrine::Component
      # 地图画布像素盒（Projector 的 box；padding 在投影内扣除）
      BOX_W = 180
      BOX_H = 120
      PADDING = 8
      # CRuby（单测/SSR）下无真实窗口，视口取固定值；浏览器由 shell 注入
      # 读 window.inner* 的 provider，保持跟随 resize
      DEFAULT_VIEWPORT = { w: 1280, h: 800 }.freeze
      # 内容保鲜间隔：文本编辑等无几何变化的内容变化也能进缩略图
      THUMB_REFRESH_MS = 1200

      prop :wm       # Beryl::WindowManager（each_window 产 record，geom 是 Signal）
      prop :camera   # Emerald::Zui::Camera
      prop :viewport, default: -> { DEFAULT_VIEWPORT } # -> { w:, h: } 屏幕视口 provider

      # SSR/CRuby 不挂监听不建 Effect，钩子内部 defined?(Opal) 守卫，安全跳过
      on_mount :setup_minimap_input, :setup_minimap_thumbs

      def view
        box(css_class: 'zui-minimap') do
          @canvas_node = box(css_class: 'zui-minimap-canvas') do
            each_window_blip
            # 缩略图锚点：无 block + key 固定——citrine 复用同一个空盒元素、
            # 从不管理其子节点，缩略图 div 由 setup_minimap_thumbs 命令式填充，
            # 组件重渲染不会清掉这些外来子节点（设计关键，见该类注释）
            @thumbs_node = box(css_class: 'zui-minimap-thumbs', key: :thumbs_anchor)
            box(css_class: 'zui-minimap-cam', style: camera_rect_style)
          end
          # 回家钮：canvas 的兄弟节点（点击不被画布 mousedown 监听抢走），
          # 绝对定位悬在面板右上角（CSS），一键 camera.home
          box(css_class: 'zui-minimap-home', tip: '回家',
              on_click: ->(_e) { camera.home }) { '⌂' }
        end
      end

      private

      # ── 投影接线（数学全在 Projector，此处只喂数据）──────

      # 显示层投影：拖拽中读冻结快照（呼吸修复，见 freeze_drag_projection），
      # 否则现算
      def projector
        @drag_projector || fresh_projector
      end

      # subscribe: false 时相机走 peek（不建立订阅）——缩略图同步 Effect 用它：
      # 相机每帧都动，订阅等于每帧重克隆全部面板；bounds 随相机的变化由
      # 保鲜定时器补齐（THUMB_REFRESH_MS）
      def fresh_projector(subscribe: true)
        Projector.new(bounds: bounds(subscribe: subscribe),
                      box: { w: BOX_W, h: BOX_H }, padding: PADDING)
      end

      # 世界包围盒：全部窗口矩形 ∪ 相机取景框——取景框永远落在图内，
      # 任何缩放下小地图都不空窗（防迷路的语义核心）
      def bounds(subscribe: true)
        rects = []
        wm.each_window { |r| rects << r.geom.get } # geom 是 Signal：开窗/拖窗自动重渲染
        cam = subscribe ? camera.get : camera.signal.peek
        vp = current_viewport
        rects << { x: -cam[:x], y: -cam[:y], w: vp[:w] / cam[:zoom], h: vp[:h] / cam[:zoom] }
        Projector.union(rects)
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
      def begin_map_nav(ev, canvas)
        return if ev[:button] != 0

        ev.preventDefault
        doc = Native(`document`)
        origin = canvas.getBoundingClientRect
        freeze_drag_projection # 先冻结再起飞：按下即飞也走冻结快照，落点不漂移
        fly_to_client_point(ev[:clientX], ev[:clientY], origin) # 按下即飞
        on_move = nil
        on_up = ->(_raw) {
          doc.removeEventListener('mousemove', on_move)
          doc.removeEventListener('mouseup', on_up)
          thaw_drag_projection
        }
        on_move = ->(raw2) {
          e2 = Native(raw2)
          fly_to_client_point(e2[:clientX], e2[:clientY], origin)
        }
        doc.addEventListener('mousemove', on_move)
        doc.addEventListener('mouseup', on_up)
      end

      # 拖拽开始：冻结当时显示层的 Projector 快照——bounds 恒含取景框，飞行中
      # 取景框移动 → 包围盒变 → 比例尺重拟合 → 光标下的世界点漂移（呼吸感）。
      # 冻结后显示层与坐标换算全程走同一快照：小地图视觉完全静止，只有取景框
      # 在静态地图上平移。普通 ivar 非 signal：view 本就因 camera 变化重跑，
      # 重跑时读它即可，无需额外响应化
      def freeze_drag_projection
        @drag_projector = fresh_projector
      end

      # 拖拽结束：扔掉快照，view 恢复动态拟合
      def thaw_drag_projection
        @drag_projector = nil
      end

      # ── 内容缩略图（真实面板克隆，非色块；CRuby 全部跳过，只留锚点盒供测试断言）──

      # 缩略图投影 = 显示层同款冻结语义（拖拽中读 @drag_projector，整体静止），
      # 平时现算但相机不订阅（fresh_projector 的 subscribe: 参数）
      def thumb_projector
        @drag_projector || fresh_projector(subscribe: false)
      end

      # 接线（Opal 专属）。两条同步通道：
      # ① 信号 Effect 读全部窗口 geom + wm z 序（读即订阅）——开窗/拖窗/
      #    焦点变化自动重同步；Effect 归锚点节点 owned_effects，卸载即释放
      # ② Beryl::Timer 链式自排（Timer 只有一次性 after）每 1200ms 重跑：内容
      #    保鲜；document.hidden 跳过本轮同步；锚点脱离文档（组件卸载）链条
      #    自然停止
      def setup_minimap_thumbs
        return unless defined?(Opal)

        anchor = @thumbs_node.dom
        tick = nil # 先声明：块内自引用
        tick = -> {
          if anchor[:isConnected]
            Beryl::Timer.after(THUMB_REFRESH_MS, &tick)
            sync_window_thumbs(anchor) unless `document.hidden`
          end
        }
        Beryl::Timer.after(THUMB_REFRESH_MS, &tick)
        @thumbs_node.owned_effects << Citrine::Effect.create { sync_window_thumbs(anchor) }
      end

      # 缩略图同步：每个窗口取世界层真实面板（shell 挂的 zui-win-<id> 挂钩类）
      # 深克隆进锚点盒，位置/尺寸 = 投影映射。整盒重建：窗口数少、克隆廉价；
      # 克隆体不经过 VDOM，重渲染不碰（外来子节点存活的关键设计，见 view）
      def sync_window_thumbs(anchor)
        proj = thumb_projector
        s = proj.scale
        doc = Native(`document`)
        anchor[:innerHTML] = ''
        wm.each_window do |r| # z 序遍历：后开窗的缩略图在上层
          # 选择器 sanitize：win_id 含 '#'（多实例 about#2）会被当成 id 选择器，
          # 规则与 shell.rb win_frame_class 的挂钩类生成必须一致（改一处另一处跟）
          # :not(.zui-morph-ghost) 双保险：形变幽灵虽已剥挂钩类（morph.rb
          # strip_hook_classes），仍显式排除——它只是视觉克隆，不是真面板
          panel = doc.querySelector(".zui-world .zui-win-#{r.id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')}:not(.zui-morph-ghost)")
          next unless panel # 面板未挂载（最小化等）：跳过，色块仍在

          g = r.geom.get
          mx, my = proj.to_map(g[:x], g[:y])
          wrapper = doc.createElement('div')
          wrapper[:className] = thumb_class(r)
          style = wrapper[:style]
          style[:position] = 'absolute'
          style[:left] = px(mx)
          style[:top] = px(my)
          style[:width] = px(g[:w] * s)
          style[:height] = px(g[:h] * s)
          style[:overflow] = 'hidden'
          style[:pointerEvents] = 'none'
          clone = panel.cloneNode(true)
          strip_clone_ids(clone)
          cs = clone[:style]
          cs[:left] = '0px' # 克隆体带着真实面板的内联定位（世界坐标），归 0——
          cs[:top] = '0px'  # 位置由 wrapper 承载，克隆体只在盒内等比缩小
          cs[:transform] = "scale(#{s.round(4)})"
          cs[:transformOrigin] = '0 0'
          wrapper.appendChild(clone)
          anchor.appendChild(wrapper)
        end
      end

      def thumb_class(r)
        "zui-minimap-thumb#{' is-active' if wm.active?(r.id)}"
      end

      # 克隆体剥掉全部 id：与真实面板同 id 进文档会串（getElementById/label for）
      def strip_clone_ids(clone)
        %x{
          var root = #{clone.to_n};
          root.removeAttribute('id');
          var els = root.querySelectorAll('[id]');
          for (var i = 0; i < els.length; i++) { els[i].removeAttribute('id'); }
        }
        nil
      end

      def setup_minimap_input
        return unless defined?(Opal)

        canvas = @canvas_node.dom
        canvas.addEventListener('mousedown', ->(raw) { begin_map_nav(Native(raw), canvas) })
      end
    end
  end
end
