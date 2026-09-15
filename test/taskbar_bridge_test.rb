# frozen_string_literal: true

# Z1 · 任务栏桥接单测（docs/PLAN.md §3.4 导航 + §3.8 形态态机）：
# beryl Taskbar 的 wm 调用面被改道——点激活窗 = 收起为图标（与 ✕ 同语义）、
# 点后台窗 = 聚焦 + 相机飞行。纯 CRuby：断言桥接的透传与改道，不碰 Opal。
require 'minitest/autorun'
require 'emerald/zui'

class ZuiTaskbarBridgeTest < Minitest::Test
  def setup
    @shell = Emerald::Zui::Shell.new
    @bridge = @shell.taskbar_bridge
  end

  def test_read_only_methods_delegate
    inst = @shell.launch_app(:about)
    ids = []
    @bridge.each_window { |rec| ids << rec.id }
    assert_includes ids, :about
    assert @bridge.active?(:about), '激活态透传'
    refute @bridge.minimized?(:about)
    refute_nil inst
  end

  def test_toggle_min_routes_to_form_collapse
    inst = @shell.launch_app(:about)
    @bridge.toggle_min(:about)

    assert_equal :icon, inst.form, '任务栏最小化 = 形态切换（窗口缩成图标）'
    assert_empty @shell.wm.windows, '窗口形态已摘'
    assert_includes Citrine.render(@shell), 'zui-iconform-about', '图标形态在场上'
  end

  def test_focus_routes_to_camera_flight
    @shell.launch_app(:about)
    @shell.launch_app(:clock)
    @shell.camera.set(x: 5000, y: 5000, zoom: 0.5)

    @bridge.focus(:about)

    assert @shell.wm.active?(:about), '聚焦语义保留'
    assert_equal :about, @shell.wm.windows.last, 'z 序提到最前'
    cam = @shell.camera.get
    refute_equal({ x: 5000.0, y: 5000.0, zoom: 0.5 }, cam, '相机飞到该窗（不再是原取景）')
    assert_in_viewport(@shell.wm.geometry(:about), cam)
  end

  private

  # 世界矩形经相机投影后应落在视口内（CRuby 视口 1280×800）
  def assert_in_viewport(rect, cam)
    vp = { w: 1280, h: 800 }
    [[rect[:x], rect[:y]], [rect[:x] + rect[:w], rect[:y] + rect[:h]]].each do |wx, wy|
      sx = (wx + cam[:x]) * cam[:zoom]
      sy = (wy + cam[:y]) * cam[:zoom]
      assert sx.between?(0, vp[:w]) && sy.between?(0, vp[:h]),
             "窗口角 (#{wx},#{wy}) 投影 (#{sx.round},#{sy.round}) 应在视口内"
    end
  end
end
