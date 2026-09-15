# frozen_string_literal: true

# Emerald::Zui — Emerald OS 的 ZUI（Zoomable User Interface）视口扩展。
# 分层、里程碑与决策见 docs/PLAN.md（唯一规划事实源）。
#
# 纪律（继承 emerald / beryl）：相机与坐标换算等核心逻辑纯 CRuby 可测；
# Opal/JS 只允许出现在渲染适配处，且 defined?(Opal) 守卫；
# 不 fork、不猴子补丁 citrine/beryl/emerald，缺口走反哺通道（PLAN §5）。
require 'emerald'
require_relative 'zui/camera'
require_relative 'zui/projector'
require_relative 'zui/minimap'
require_relative 'zui/shell'

module Emerald
  module Zui
  end
end
