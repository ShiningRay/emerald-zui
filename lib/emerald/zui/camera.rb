# frozen_string_literal: true

module Emerald
  module Zui
    # Z0 · 相机服务：{x, y, zoom} 单信号持有桌面相机的取景状态，
    # 所见一切皆相机取景（docs/PLAN.md §3.1）。纯 CRuby 可测，零 Opal 依赖。
    #
    # 坐标语义（单测锁定，勿改）：
    #   screen = (world + {x, y}) * zoom     # 世界原点相对屏幕左上角的偏移
    #   world  = screen / zoom - {x, y}
    # 对应世界层容器的 CSS transform（origin 0 0，D2）：
    #   translate(x*zoom px, y*zoom px) scale(zoom)
    #
    # 变更纪律（beryl F6 同款守卫）：set/zoom_at/pan_by/fit/center_on 只能在
    # 事件回调（wheel/drag/快捷键/任务栏点击/小地图导航）里调用，view/Effect 内
    # 直接 raise。
    class Camera
      MIN_ZOOM = 0.1
      MAX_ZOOM = 4.0
      DEFAULT_STATE = { x: 0.0, y: 0.0, zoom: 1.0 }.freeze
      DEFAULT_FIT_PADDING = 40

      # 内部 Signal 供 Effect 订阅（世界层 transform 直写 DOM 的那一台）；
      # 取新鲜值请走 #get——内部存储冻结，相等写入会被 Signal 短路、不广播。
      attr_reader :signal

      # state 为 nil 取默认值；给哈希则合并进默认值后钳制（缺省键由默认补齐）。
      def initialize(state = nil)
        initial = state ? DEFAULT_STATE.merge(state) : DEFAULT_STATE.dup
        @signal = Citrine::Signal.new(clamp_and_freeze(normalize(initial)))
      end

      # 新鲜 Hash（x/y/zoom 三个 Float）；Effect 内调用会订阅相机（LOD 分档等）。
      def get
        s = @signal.get
        { x: s[:x], y: s[:y], zoom: s[:zoom] }
      end

      # ── 变更（只允许事件回调进入，F6 守卫）───────────────

      # 整体替换并钳制 zoom（缺键 raise ArgumentError，不做字段级合并）。
      def set(state)
        assert_outside_effect!(:set)
        @signal.set(clamp_and_freeze(normalize(state)))
      end

      # 以屏幕点 (sx, sy) 为锚缩放：锚点下的世界坐标缩放前后在屏幕上不动
      # （单测核心断言）。z' = clamp(zoom*factor)；x' = x + sx*(1/z' - 1/zoom)。
      def zoom_at(sx, sy, factor)
        assert_outside_effect!(:zoom_at)
        s = @signal.peek
        z = clamp_zoom(s[:zoom] * factor)
        set(x: s[:x] + sx * (1.0 / z - 1.0 / s[:zoom]),
            y: s[:y] + sy * (1.0 / z - 1.0 / s[:zoom]),
            zoom: z)
      end

      # 屏幕像素位移换算进世界（抓取语义，内容跟随光标）：
      # 光标向右拖 dx → 内容右移 dx → x' = x + dx/zoom。
      # 恒等式 screen = (world + {x,y})*zoom：x 增大，同一世界点在屏幕上右移。
      def pan_by(dx, dy)
        assert_outside_effect!(:pan_by)
        s = @signal.peek
        set(x: s[:x] + dx / s[:zoom], y: s[:y] + dy / s[:zoom], zoom: s[:zoom])
      end

      # 飞到世界矩形（任务栏点击 / 最大化 / ⌘0 全景）：
      # z' 取双轴受限比 clamp(min((vw-2p)/w, (vh-2p)/h))，矩形中心对齐视口中心。
      # 中心对齐公式由锁定恒等式 screen = (world + cam)*zoom 推出：
      #   x' = vw/(2*z') - (rect.x + w/2)
      # （注意：不是 translate 参数写法 vw/2 - cx*z'——两者差一个 z' 因子，
      #   以恒等式为准；单测锁矩形中心 → 视口中心）。
      # rect/viewport 的 w/h <= 0 时安全退化：不改缩放，仅尽量居中。
      def fit(rect, viewport, padding: DEFAULT_FIT_PADDING)
        assert_outside_effect!(:fit)
        rw = Float(rect[:w])
        rh = Float(rect[:h])
        vw = Float(viewport[:w])
        vh = Float(viewport[:h])
        cx = Float(rect[:x]) + rw / 2
        cy = Float(rect[:y]) + rh / 2
        s = @signal.peek

        if rw <= 0.0 || rh <= 0.0 || vw <= 0.0 || vh <= 0.0
          set(x: vw / 2 / s[:zoom] - cx, y: vh / 2 / s[:zoom] - cy, zoom: s[:zoom])
        else
          z = clamp_zoom([(vw - 2.0 * padding) / rw, (vh - 2.0 * padding) / rh].min)
          set(x: vw / 2 / z - cx, y: vh / 2 / z - cy, zoom: z)
        end
      end

      # 保持 zoom，把世界点 (wx, wy) 移到视口中心（小地图点击/拖拽导航）：
      # 由锁定恒等式 screen = (world + {x,y})*zoom 推出中心对齐
      #   x' = vw/(2*zoom) - wx；y' = vh/(2*zoom) - wy
      # viewport 形参 {w:, h:}（与 fit 同款）；视口 w/h ≤ 0 时公式自然退化，
      # 世界点落在屏幕原点方向，不 raise。
      def center_on(wx, wy, viewport)
        assert_outside_effect!(:center_on)
        s = @signal.peek
        vw = Float(viewport[:w])
        vh = Float(viewport[:h])
        set(x: vw / 2.0 / s[:zoom] - Float(wx),
            y: vh / 2.0 / s[:zoom] - Float(wy),
            zoom: s[:zoom])
      end

      # ── 坐标换算（纯读取，任何上下文可调）────────────────

      def world_to_screen(wx, wy)
        s = @signal.peek
        [(wx + s[:x]) * s[:zoom], (wy + s[:y]) * s[:zoom]]
      end

      def screen_to_world(sx, sy)
        s = @signal.peek
        [sx / s[:zoom] - s[:x], sy / s[:zoom] - s[:y]]
      end

      private

      def normalize(state)
        missing = %i[x y zoom].reject { |k| state.key?(k) }
        raise ArgumentError, "相机状态缺少键：#{missing.join('、')}" unless missing.empty?

        { x: Float(state[:x]), y: Float(state[:y]), zoom: Float(state[:zoom]) }
      end

      def clamp_and_freeze(state)
        state.merge(zoom: clamp_zoom(state[:zoom])).freeze
      end

      def clamp_zoom(z)
        z.clamp(MIN_ZOOM, MAX_ZOOM)
      end

      def assert_outside_effect!(op)
        return unless Citrine::Effect.current

        raise ArgumentError,
              "Camera##{op} 不能在 view/Effect 内调用（set 会同步重入渲染）。" \
              "相机变更请从事件回调进入（wheel/drag/快捷键/任务栏点击）。"
      end
    end
  end
end
