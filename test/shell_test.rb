# frozen_string_literal: true

# Z0 · ZuiShell 单测（docs/PLAN.md §3.2/§6）：世界层/HUD 分层组装、相机接线、
# 滚轮缩放/拖拽平移的纯逻辑（transform 串、滚轮因子、落点回写）。
# 纯 CRuby（beryl F5）：StringRenderer 渲染 + 直接方法断言，不触碰 Opal；
# 相机数学本身的断言归 camera_test（§3.1 契约）。
require 'minitest/autorun'
require 'emerald/zui'

class ZuiShellTest < Minitest::Test
  def setup
    @shell = Emerald::Zui::Shell.new
  end

  def render_html(shell = @shell)
    Citrine.render(shell)
  end

  # ── 分层组装（PLAN §3.2）─────────────────────────────

  def test_stage_wraps_world_and_hud_comes_after
    html = render_html
    stage_at = html.index('zui-stage')
    world_at = html.index('zui-world')
    hud_at = html.index('zui-hud')
    refute_nil stage_at, '舞台层（屏幕固定：手势 + 视觉底层）应存在'
    refute_nil world_at, '世界层容器应存在'
    refute_nil hud_at, 'HUD 层容器应存在'
    assert_operator stage_at, :<, world_at, '世界层应在舞台层内'
    assert_operator world_at, :<, hud_at, '世界层应先于 HUD 层（DOM 序 = 层叠序）'
    assert_operator html.index('icon-grid'), :>, world_at, '图标网格应在世界层内'
    assert_nil html.index('desktop-wallpaper'),
               '壁纸不再渲染世界内壁纸盒（越界露馅），改由 .zui-stage 的 CSS 背景承载'
  end

  def test_hud_layer_holds_menubar_taskbar_tray
    html = render_html
    hud_at = html.index('zui-hud')
    assert_operator html.index('b-menubar'), :>, hud_at, '菜单栏应在 HUD 层'
    assert_operator html.index('b-taskbar'), :>, hud_at, '任务栏应在 HUD 层'
    assert_operator html.index('tray-clock'), :>, hud_at, '托盘应在 HUD 层'
  end

  def test_open_window_renders_inside_world_layer
    @shell.launch_app(:about)
    html = render_html
    win_at = html.index(/class="panel/)
    refute_nil win_at, '窗口框应渲染'
    assert_operator html.index('zui-world'), :<, win_at
    assert_operator win_at, :<, html.index('zui-hud'), '窗口应渲染在世界层（相机容器）内，而非 HUD'
    assert_operator html.index('b-taskbtn'), :>, html.index('zui-hud'), '任务栏按钮仍在 HUD'
  end

  # ── 相机接线 ─────────────────────────────────────────

  def test_camera_wired_with_default_state
    assert_instance_of Emerald::Zui::Camera, @shell.camera
    assert_equal({ x: 0.0, y: 0.0, zoom: 1.0 }, @shell.camera.get)
  end

  def test_wm_viewport_nil_in_zui_mode
    assert_nil @shell.wm.viewport, 'ZUI 无限画布：视口钳制与边缘吸附应关闭（PLAN §3.3）'
  end

  def test_camera_transform_matches_identity
    assert_equal 'translate(0px, 0px) scale(1)',
                 @shell.send(:camera_transform, { x: 0, y: 0, zoom: 1 })
    assert_equal 'translate(20px, 40px) scale(2)',
                 @shell.send(:camera_transform, { x: 10, y: 20, zoom: 2 }),
                 'translate 分量 = x·zoom / y·zoom（PLAN §3.1 恒等式对应 CSS）'
  end

  # ── 滚轮缩放（事件回调链的纯逻辑段）────────────────────

  def test_wheel_factor_direction_and_inverse
    assert_in_delta 1.0, @shell.send(:wheel_factor, 0)
    assert_operator @shell.send(:wheel_factor, -100), :>, 1, 'delta_y<0（上滚）应放大'
    assert_operator @shell.send(:wheel_factor, 100), :<, 1, 'delta_y>0（下滚）应缩小'
    assert_in_delta(1.0, @shell.send(:wheel_factor, 120) * @shell.send(:wheel_factor, -120),
                    1e-12, '往返滚动的因子互逆')
  end

  def test_zoom_at_point_zooms_toward_pointer
    @shell.send(:zoom_at_point, { x: 400.0, y: 300.0, delta_y: -100 })
    cam = @shell.camera
    assert_in_delta Math.exp(0.1), cam.get[:zoom], 1e-9
    # 锚点不动性：缩放前后，锚点屏幕坐标对应的世界点在屏幕上位置不变（§3.1）
    after = cam.world_to_screen(*cam.screen_to_world(400.0, 300.0))
    assert_in_delta 400.0, after[0], 1e-6
    assert_in_delta 300.0, after[1], 1e-6
  end

  # ── 拖拽平移（落点回写）───────────────────────────────

  def test_commit_pan_writes_back_camera
    @shell.send(:commit_pan, { dx: 12.0, dy: 8.0 })
    c = @shell.camera.get
    assert_in_delta(12.0, c[:x], 1e-9, 'pan_by 抓取语义：x′ = x + dx/zoom（zoom=1）')
    assert_in_delta(8.0, c[:y], 1e-9)
  end
end
