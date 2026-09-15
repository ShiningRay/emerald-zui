# frozen_string_literal: true

module Emerald
  module Zui
    # Beryl::Taskbar 的 wm 装饰器（PLAN §3.4 导航 + §3.8 形态态机）：
    # 任务栏只用到 each_window / active? / minimized? / toggle_min / focus
    # 五个方法，这里把两处语义改道，而不 fork beryl 组件：
    #   ① toggle_min（点激活窗）→ 形态切换（窗口缩成图标，与 ✕ 同语义）
    #   ② focus（点后台窗）→ 聚焦 + 相机飞行到该窗（Z1「任务栏=fit」）
    # 只读方法原样透传；beryl Taskbar 的其余调用面若有变化，本类会因
    # NoMethodError 立即暴露（比静默走错语义好）。
    class TaskbarBridge
      def initialize(wm:, shell:)
        @wm = wm
        @shell = shell
      end

      def each_window(&block)
        @wm.each_window(&block)
      end

      def active?(id)
        @wm.active?(id)
      end

      def minimized?(id)
        @wm.minimized?(id)
      end

      def toggle_min(id)
        @shell.collapse_window(id)
      end

      def focus(id)
        @shell.focus_window_with_flight(id)
      end
    end
  end
end
