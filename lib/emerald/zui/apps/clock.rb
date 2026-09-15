# frozen_string_literal: true

module Emerald
  module Zui
    module Apps
      # 时钟（Z1.5 形态态机 dogfood，docs/PLAN.md §3.8 活图标示例）：
      #   窗口形态 = 模拟钟面（表盘 + 12 刻度 + 时针/分针）；
      #   图标形态 = 两根指针的小表盘（覆写 AppForm#icon_view，D7 覆写点）。
      # 两形态读同一 now signal ——形态变形（Morph）前后指针逐帧一致、同步走字，
      # 这正是「图标形态是实例的活跃视图」的红利演示：活图标 = 普通状态驱动渲染，
      # 无需小地图式的克隆快照/保鲜机制。
      #
      # 秒针不渲染：分钟粒度 tick（PLAN 定案，省电防抖）——Beryl::Timer 一次性
      # 语义，每次对表后排程到下一分钟边界。样式全内联（本仓路由纪律：不碰 CSS 文件）。
      class Clock < Emerald::App
        app_id :clock
        app_title '时钟'
        app_icon '◷'
        default_geometry { { x: 180, y: 120, w: 320, h: 340 } }

        # 表盘尺寸：窗口形态 / 图标形态（px）
        DIAL_PX = 260
        ICON_PX = 56
        # 配色（内联样式的唯一来源）
        DIAL_BG = '#141821'
        EDGE    = '#3a4356'
        HAND    = '#e6e9f0'
        TICK    = '#8a93a5'
        PIN     = '#e6e9f0'
        TICK_W  = 2

        class << self
          # 抹掉秒与亚秒 → 分钟粒度时间点（本地时区；Opal 同语义：Time.at(整数) = 本地）
          def snap(t)
            Time.at(t.to_i - t.sec)
          end

          # 到下一分钟边界的毫秒数（tick 排程用）：sec=0 → 60000，sec=59.999 → ≈0
          def ms_until_next_minute(t)
            (60 - t.sec) * 1000 - (t.usec / 1000.0).round
          end

          # 两根指针的转角（deg，0 = 12 点方向，顺时针）：
          # 分针 6°/分；时针 30°/时 + 0.5°/分（随分钟连续爬行，非整点跳变）
          def hand_angles(t)
            { hour: (t.hour % 12) * 30 + t.min * 0.5, minute: t.min * 6 }
          end
        end

        # 分钟粒度 now：初值惰性取当前分钟（SSR/未 boot 直接渲染也显示正确时间）
        state(:now) { Clock.snap(Time.now) }

        # 生命周期挂 boot/deactivate 而非 on_mount：app 实例经 content 插槽渲染
        # （shell 的 -> { inst.view }），不走过 mount_component/render_component，
        # 实例的 on_mount/on_unmount 钩子不会被调用（citrine renderer 只在两处
        # 跑 run_mount_hooks）——registry 的 launch/dispose 是唯一可靠生命周期。
        # 形态切换 window→icon 只 wm.close、实例留 registry（PLAN §3.8），
        # 定时器随实例存活：图标形态的指针因此天然继续走字。
        def boot(ctx)
          super
          start_ticking
        end

        def deactivate
          stop_ticking
          super
        end

        # 窗口形态：模拟钟面
        def view
          stack(style: { width: '100%', height: '100%', align_items: 'center',
                         justify_content: 'center', background: DIAL_BG }) do
            face(DIAL_PX, ticks: true)
          end
        end

        # 图标形态（D7 活图标）：只有两根指针的小表盘——与窗口形态同一 now signal，
        # 读信号 → 分钟 tick 驱动两手 transform: rotate 原地重渲染（PLAN §3.8）
        def icon_view
          face(ICON_PX, ticks: false)
        end

        private

        # 表盘 + 指针的共享渲染（两形态唯一差异 = 尺寸与刻度）：
        # 指针是 absolute 定位于盘心下方 50% 的竖条，transform-origin 在底边
        # 中点（= 盘心），rotate(0) 即指向 12 点
        def face(px, ticks:)
          angles = Clock.hand_angles(now)
          box(css_class: 'zui-clock-dial', style: { position: 'relative',
                                                    width: px, height: px,
                                                    border_radius: '50%',
                                                    background: DIAL_BG,
                                                    border: "2px solid #{EDGE}" }) do
            tick_ring(px) if ticks
            hand(:hour, angles[:hour], px)
            hand(:minute, angles[:minute], px)
            pin(px)
          end
        end

        # 指针：时针短粗（半径 50%）、分针细长（半径 74%）
        def hand(kind, deg, px)
          weight = kind == :hour ? 5 : 3
          length = ((kind == :hour ? 0.5 : 0.74) * px).round
          box(css_class: "zui-clock-hand zui-clock-hand-#{kind}", style: {
                position: 'absolute', left: '50%', bottom: '50%',
                width: weight, height: length, background: HAND,
                border_radius: weight / 2.0,
                transform_origin: '50% 100%',
                transform: "translateX(-50%) rotate(#{fmt_deg(deg)}deg)"
              })
        end

        # 12 时刻度：整高细条绕盘心旋转，顶端露出的一小段即刻度
        def tick_ring(px)
          12.times do |i|
            box(css_class: 'zui-clock-tick', style: {
                  position: 'absolute', left: '50%', top: '50%',
                  width: TICK_W, height: px,
                  transform: "translate(-50%, -50%) rotate(#{i * 30}deg)"
                }) do
              box(style: { width: TICK_W, height: (px * 0.06).round,
                           background: TICK, border_radius: TICK_W / 2.0,
                           margin: '0 auto' })
            end
          end
        end

        # 盘心轴帽
        def pin(px)
          d = (px * 0.055).round.clamp(4, 14)
          box(css_class: 'zui-clock-pin', style: { position: 'absolute',
                                                   left: '50%', top: '50%',
                                                   width: d, height: d,
                                                   border_radius: '50%',
                                                   background: PIN,
                                                   transform: 'translate(-50%, -50%)' })
        end

        # 转角格式化：整数值去小数点（90.0 → "90"），x.5 保留
        def fmt_deg(deg)
          deg == deg.to_i ? deg.to_i : deg
        end

        # ── 分钟粒度 tick 链（Beryl::Timer 一次性语义，到点重排）────────

        def start_ticking
          tick
        end

        def tick
          self.now = Clock.snap(Time.now)
          @timer = Beryl::Timer.after(Clock.ms_until_next_minute(Time.now)) { tick }
        end

        def stop_ticking
          Beryl::Timer.cancel(@timer)
          @timer = nil
        end
      end
    end
  end
end
