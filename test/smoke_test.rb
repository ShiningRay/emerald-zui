# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald/zui'

# 冒烟：入口可加载、常量就位（Z0 起由 camera_test/shell_test 接管实质断言）
class SmokeTest < Minitest::Test
  def test_entry_loads
    assert defined?(Emerald::Zui)
    assert defined?(Emerald::Zui::Camera)
    assert Emerald::Zui::Shell < Emerald::DesktopShell
  end
end
