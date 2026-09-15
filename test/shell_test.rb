# frozen_string_literal: true

# Z0 · ZuiShell 单测（docs/PLAN.md §3.2/§6）：世界层/HUD 分层组装、相机接线、
# 滚轮缩放/拖拽平移的纯逻辑（transform 串、滚轮因子、落点回写）。
# 纯 CRuby（beryl F5）：StringRenderer 渲染 + 直接方法断言，不触碰 Opal；
# 相机数学本身的断言归 camera_test（§3.1 契约）。
require 'minitest/autorun'
require 'emerald/zui'

# Clock 命名空间守卫（并行路线实现 clock.rb 后模块已存在；此处只为
# 注册守卫的单测提供 stub 挂点，幂等）
unless defined?(Emerald::Zui::Apps)
  module Emerald::Zui::Apps; end
end

# Z1.5 多实例假人（单例语义已被 About 覆盖，去重/级联需要多实例应用）：
# 注册进各测试的崭新 shell.registry，互不染
ZuiMorphTestApp = Class.new(Emerald::App) do
  app_id :morph_test
  app_title '形态多开'
  app_icon '▣'
  default_geometry { { x: 100, y: 100, w: 200, h: 150 } }

  def view
    label { 'morph' }
  end
end

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

  def test_hud_layer_holds_minimap_with_camera_rect
    html = render_html
    hud_at = html.index('zui-hud')
    minimap_at = html.index('zui-minimap')
    refute_nil minimap_at, '小地图应在 HUD 层（屏幕固定，不随相机变换）'
    assert_operator minimap_at, :>, hud_at
    assert_operator html.index('zui-minimap-cam'), :>, hud_at,
                    '空世界也渲染相机取景框（防迷路底线）'
    refute_includes html, 'zui-minimap-win'

    @shell.launch_app(:about)
    html = render_html
    assert_operator html.index('zui-minimap-win'), :>, hud_at, '开窗后小地图应有窗块'
    assert_operator html.index('class="panel'), :<, hud_at, '窗口本体仍在世界层'
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

  def test_window_frames_carry_minimap_hook_class
    @shell.launch_app(:about)
    html = render_html
    assert_includes html, 'zui-win-about', '每窗稳定挂钩类：小地图缩略图取真实面板用'
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

  # ── Z1.5 · 形态态机（PLAN §3.8：窗口即图标，同一实例两形态）──────

  def test_morph_to_icon_replaces_window_with_live_tile
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)

    assert_equal :icon, inst.form
    assert_empty @shell.wm.windows, 'wm 只登记窗口形态实例（实例留 registry）'
    assert_equal({ x: 200, y: 120, w: 380, h: 280 }, inst.window_geometry_backup,
                 '缩起暂存窗口几何')
    assert_equal({ x: 120, y: 90 }, inst.icon_geometry,
                 '锚位在启动时定（§3.8 修订）：CRuby 无 DOM 取不到启动器槽位 → ' \
                 '退化为兜底几何级联序 0，与窗口位置无关')

    html = render_html
    assert_includes html, 'zui-iconform d-icon zui-iconform-about', 'tile 挂钩类（契约）'
    assert_includes html, 'd-icon-glyph', '默认 icon_view：glyph（D7 兼容降级）'
    assert_includes html, '◈', 'glyph 取 app_icon'
    assert_includes html, 'left:120px;top:90px', 'tile 定位于驻留几何（世界坐标）'
    refute_includes html, 'panel-head', '窗口本体不渲染（form 分派）'
  end

  def test_morph_to_window_restores_backup_geometry
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)
    @shell.morph_to_window(inst)

    assert_equal :window, inst.form
    assert_includes @shell.wm.windows, :about
    assert_equal({ x: 200, y: 120, w: 380, h: 280 }, @shell.wm.geometry(:about),
                 '几何取 backup 恢复，不走默认级联')
    assert_nil inst.window_geometry_backup, 'backup 已消费'
    refute_includes render_html, 'zui-iconform-about', '图标 tile 消失'
  end

  def test_window_minimize_button_wired_to_morph
    inst = @shell.launch_app(:about)
    @shell.send(:window_frame, inst).on_minimize.call

    assert_equal :icon, inst.form, 'ZUI 语义：最小化 = 缩成图标（§3.8 最小化按钮触发）'
    assert_empty @shell.wm.windows
    assert_includes render_html, 'zui-iconform-about'
  end

  def test_classic_toggle_min_keeps_window_form
    inst = @shell.launch_app(:about)
    @shell.wm.toggle_min(:about)

    assert_equal :window, inst.form, '任务栏最小化暂走经典 toggle_min（§3.9），形态不变'
    assert_includes @shell.wm.windows, :about
  end

  def test_each_instance_morphs_independently_with_sanitized_classes
    @shell.registry.register(ZuiMorphTestApp)
    a = nil
    b = nil
    @shell.stub(:now_ms, 1000) { a = @shell.launch_app(:morph_test) }
    @shell.stub(:now_ms, 5000) { b = @shell.launch_app(:morph_test) }
    refute_same a, b, '去重窗外两次启动 = 两个独立实例'

    @shell.morph_to_icon(a)
    assert_equal :window, b.form, '多实例各自独立形态'
    assert_includes @shell.wm.windows, :'morph_test#2', 'b 仍在窗口登记'

    html = render_html
    assert_includes html, 'zui-iconform d-icon zui-iconform-morph_test'

    @shell.morph_to_icon(b)
    assert_includes render_html, 'zui-iconform d-icon zui-iconform-morph_test_2',
                    '多实例 id 的 # 消毒为 _（与 win_frame_class 同规则）'
    assert_equal({ x: 144, y: 114 }, b.icon_geometry,
                 '级联序 1（§3.8 修订：锚位在启动时定，CRuby 兜底几何 + 24 错开）')
  end

  def test_icon_drag_reposition_writes_resident_geometry
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)
    @shell.place_icon_at({ inst: inst, x: 400.0, y: 300.0 })

    assert_equal({ x: 400.0, y: 300.0 }, inst.icon_geometry, '驻留几何落点回写（F6 安全区）')
    assert_includes render_html, 'left:400.0px;top:300.0px', '驻留几何直写 tile 世界定位'
  end

  def test_relaunch_singleton_in_icon_form_restores_window
    inst = nil
    @shell.stub(:now_ms, 1000) { inst = @shell.launch_app(:about) }
    @shell.morph_to_icon(inst)
    @shell.stub(:now_ms, 5000) { @shell.launch_app(:about) }

    assert_equal :window, inst.form, '图标形态单例再启动 = 涨回窗口（morph 恢复备份几何）'
    assert_includes @shell.wm.windows, :about
    assert_equal({ x: 200, y: 120, w: 380, h: 280 }, @shell.wm.geometry(:about))
  end

  # ── Z1.5 修订（§3.8 表征互斥 + 槽位恒定，2026-09-16 用户复查）──────

  def test_launcher_yields_slot_while_instance_exists
    html = render_html
    assert_includes html, 'd-icon d-icon-app-about', '无实例：启动器在位（带槽位挂钩类）'

    inst = @shell.launch_app(:about)
    refute_includes render_html, 'd-icon-app-about',
                    '表征互斥：有实例（窗口形态）时启动器让位——一个应用不出现两个图标'

    @shell.morph_to_icon(inst)
    html = render_html
    refute_includes html, 'd-icon-app-about', '收起态：槽位由实例的图标形态接管'
    assert_includes html, 'zui-iconform d-icon zui-iconform-about'

    @shell.quit_app(:about)
    assert_includes render_html, 'd-icon-app-about', '退出后启动器回归'
  end

  def test_close_collapses_to_icon_instead_of_disposing
    inst = @shell.launch_app(:about)
    @shell.close_window(:about)

    assert_equal :icon, inst.form, '✕/⌘W 在 ZUI = 收起为图标（不销毁实例）'
    assert_same inst, @shell.registry.instance(:about), '实例仍在 registry'
    assert_empty @shell.wm.windows, '窗口记录已摘'
    assert_includes render_html, 'zui-iconform d-icon zui-iconform-about', '还原为图标'
  end

  def test_quit_app_disposes_instance_and_file_icon_route_untouched
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)
    @shell.quit_app(:about)

    assert_nil @shell.registry.instance(:about), '真退出：实例销毁（D3 close 语义）'
    refute_includes render_html, 'zui-iconform-about'
    assert_empty @shell.wm.windows
  end

  def test_quit_active_app_prefers_window_then_icon_form
    a = @shell.launch_app(:about)
    @shell.morph_to_icon(a)
    @shell.quit_active_app
    assert_nil @shell.registry.instance(:about), '无窗口时退最近收起的图标形态实例'

    @shell.stub(:now_ms, 9000) { @shell.launch_app(:files) }
    @shell.quit_active_app
    assert_nil @shell.registry.instance(:files), '有窗口时退活动窗口'
  end

  def test_menubar_has_quit_entry
    apps_menu = @shell.menubar_data.find { |menu| menu[:label] == '应用' }
    labels = apps_menu[:items].map { |item| item[:label] }.compact
    assert_includes labels, '退出当前应用 ⌘Q', '⌘Q 之外的可发现性入口'
  end

  def test_anchor_assigned_at_launch_not_at_minimize
    inst = @shell.launch_app(:about)
    assert_equal({ x: 120, y: 90 }, inst.icon_geometry,
                 '锚位在启动时定（槽位恒定不变量）：CRuby 取不到启动器槽位 → 兜底级联')

    @shell.wm.place(:about, { x: 700, y: 500, w: 380, h: 280 })
    @shell.morph_to_icon(inst)
    assert_equal({ x: 120, y: 90 }, inst.icon_geometry,
                 '窗口后来移动不影响锚位——缩回的是图标原本所在处')
  end

  def test_restore_right_after_minimize_not_eaten_by_dedup
    inst = nil
    @shell.stub(:now_ms, 1000) { inst = @shell.launch_app(:about) }
    @shell.morph_to_icon(inst)
    # 最小化后立刻再启动（仍在原启动的去重窗内）：恢复优先于去重
    @shell.stub(:now_ms, 1100) { @shell.launch_app(:about) }

    assert_equal :window, inst.form
  end

  # ── Z1.5 · 启动去重守卫（PLAN §8「双击图标双触发」）──────────

  def test_launch_dedup_guard_merges_same_tick_relaunch
    @shell.registry.register(ZuiMorphTestApp)
    @shell.stub(:now_ms, 1000) do
      @shell.launch_app(:morph_test)
      @shell.launch_app(:morph_test)
    end
    assert_equal 1, @shell.wm.windows.size, '同 tick 重复启动合并为一次（双击双触发守卫）'

    @shell.stub(:now_ms, 5000) { @shell.launch_app(:morph_test) }
    assert_equal 2, @shell.wm.windows.size, '去重窗外再启动正常多开'
  end

  def test_launch_dedup_guard_skips_argv_launches
    @shell.registry.register(ZuiMorphTestApp)
    @shell.stub(:now_ms, 1000) do
      @shell.launch_app(:morph_test, path: 'a')
      @shell.launch_app(:morph_test, path: 'b')
    end
    assert_equal 2, @shell.wm.windows.size, '带参启动不走守卫（open_file 连开不同文件不误吞）'
  end

  # ── Z1.5 · Clock 注册（契约：Zui::Apps::Clock / :clock / '时钟'）──

  def test_clock_registered_when_class_available
    fake_clock = Class.new(Emerald::App) do
      app_id :clock
      app_title '时钟'
      def view
        label { 'clock' }
      end
    end
    mod = Emerald::Zui::Apps
    mod.stub(:const_defined?, true, [:Clock, false]) do
      mod.stub(:const_get, fake_clock, [:Clock, false]) do
        shell = Emerald::Zui::Shell.new
        entry = shell.registry.apps.find { |a| a[:id] == :clock }
        refute_nil entry, 'Clock 落地后注册表应有 :clock（桌面图标/菜单自动出现）'
        assert_equal '时钟', entry[:title]
      end
    end
  end

  def test_shell_boots_when_clock_unavailable
    mod = Emerald::Zui::Apps
    mod.stub(:const_defined?, false, [:Clock, false]) do
      shell = Emerald::Zui::Shell.new
      refute_includes shell.registry.apps.map { |a| a[:id] }, :clock
    end
  end
end
