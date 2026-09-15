# frozen_string_literal: true

module Emerald
  module Zui
    # ZUI 桌面外壳：Emerald::DesktopShell 的子类，Z0 起逐步把 view 拆成
    # 世界层（transform 容器）+ HUD 层。当前为透传桩——经典模式即
    # 相机 {0, 0, 1} 的退化形态（docs/PLAN.md D3）。
    class Shell < Emerald::DesktopShell
    end
  end
end
