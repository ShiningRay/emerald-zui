# frozen_string_literal: true

# Emerald::Zui 整机示例（浏览器）——演示页即整机（docs/PLAN.md §7）
# 运行：在 citrine 仓库执行
#   bin/citrine dev ../emerald-zui/examples -I ../beryl/lib -I ../emerald/lib -I ../emerald-zui/lib
# 编译（emerald-zui/ 目录内）：bundle exec rake compile
require 'citrine/browser'
require 'emerald/zui'

# ZUI 整机入口：Emerald::Zui::Shell = DesktopShell + 相机视口（Z0 起填充）
shell = Emerald::Zui::Shell.new
Beryl::Renderer.mount_at('app', shell)
