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
    assert_equal({ x: 16, y: 40, w: 380, h: 280 }, inst.window_geometry_backup,
                 '缩起暂存窗口几何（窗口开在锚位槽 (16,40)）')
    assert_equal({ x: 16, y: 40, w: 80, h: 69 }, inst.icon_geometry,
                 '锚位在启动时定（§3.8 修订③）：桌面无启动器后取图标列空槽 0')

    html = render_html
    assert_includes html, 'zui-iconform d-icon zui-iconform-about', 'tile 挂钩类（契约）'
    assert_includes html, 'd-icon-glyph', '默认 icon_view：glyph（D7 兼容降级）'
    assert_includes html, '◈', 'glyph 取 app_icon'
    assert_includes html, 'left:16px;top:40px', 'tile 定位于锚位槽（世界坐标）'
    refute_includes html, 'panel-head', '窗口本体不渲染（form 分派）'
  end

  def test_morph_to_window_restores_backup_geometry
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)
    @shell.morph_to_window(inst)

    assert_equal :window, inst.form
    assert_includes @shell.wm.windows, :about
    assert_equal({ x: 16, y: 40, w: 380, h: 280 }, @shell.wm.geometry(:about),
                 '位置 = 图标锚位（原地长出），尺寸取 backup——图标拖到哪窗口就出在哪')
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
    assert_equal({ x: 16, y: 123, w: 80, h: 69 }, b.icon_geometry,
                 '锚位槽 1（列优先顺排：40 + 83）')
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
    assert_equal({ x: 16, y: 40, w: 380, h: 280 }, @shell.wm.geometry(:about),
                 '单例再启动：窗口回到图标锚位 + backup 尺寸')
  end

  # 用户复查缺陷回归：图标拖动换位后双击，窗口必须出现在**图标当前所在处**
  # （曾用「上次窗口几何」定位——图标拖到哪都无效，窗口跑回旧位置）
  def test_window_grows_at_dragged_icon_position
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)
    @shell.place_icon_at({ inst: inst, x: 640.0, y: 420.0 })

    @shell.morph_to_window(inst)
    assert_equal({ x: 640, y: 420, w: 380, h: 280 }, @shell.wm.geometry(:about),
                 '窗口 = 图标当前位置长出（位置随图标，尺寸随窗口备份）')
  end

  # ── 应用服务面（ctx[:zui]，D10）：启动器应用的操作入口 ─────────────

  def test_zui_service_surface_exposed
    zui = @shell.services[:zui]
    assert_equal %i[collapse focus launch quit restore], zui.keys.sort,
                 '服务面键集（应用只认这一张表）'

    inst = @shell.launch_app(:about)
    zui[:collapse].call(:about)
    assert_equal :icon, inst.form, 'collapse → 收起为图标'
    zui[:restore].call(:about)
    assert_equal :window, inst.form, 'restore → 涨回窗口'
    zui[:focus].call(:about)
    assert @shell.wm.active?(:about), 'focus → 聚焦（+ 相机飞行）'
    zui[:quit].call(:about)
    assert_nil @shell.registry.instance(:about), 'quit → 真退出'
  end

  def test_zui_service_launch_from_window_still_opens
    @shell.launch_app(:spotlight)
    @shell.services[:zui][:launch].call(:about, :spotlight)
    assert_includes @shell.wm.windows, :about, '带来源窗口的启动照常开窗（CRuby 无形变）'
    assert_equal :window, @shell.registry.instance(:about).form
  end

  def test_zui_service_launch_opens_window
    @shell.services[:zui][:launch].call(:about)
    assert_includes @shell.wm.windows, :about, 'launch 经 shell 开窗（R2：registry 只建实例）'
  end

  # ── Z1 导航（§3.4：相机飞行 / ⌘0 全景 / 最大化=fit）──────────────

  def test_overview_fits_all_windows_into_viewport
    @shell.stub(:now_ms, 1000) { @shell.launch_app(:about) }
    @shell.stub(:now_ms, 5000) { @shell.launch_app(:clock) }
    @shell.wm.place(:about, { x: -800, y: -400, w: 380, h: 280 })
    @shell.wm.place(:clock, { x: 1600, y: 1200, w: 320, h: 340 })

    @shell.overview

    cam = @shell.camera.get
    assert_operator cam[:zoom], :<, 1.0, '全景必然缩小到装得下所有窗口'
    [-800, 1600].each_slice(1) do |(x)|
      sx = (x + cam[:x]) * cam[:zoom]
      assert sx.between?(-1, 1281), "窗口 x=#{x} 应入视野（投影 #{sx.round}）"
    end
  end

  def test_overview_includes_icon_form_instances
    inst = @shell.launch_app(:about)
    @shell.morph_to_icon(inst)
    @shell.place_icon_at({ inst: inst, x: 5000, y: 4000 }) # 收起态拖远

    @shell.overview

    cam = @shell.camera.get
    sx = (5000 + cam[:x]) * cam[:zoom]
    assert sx.between?(-1, 1281), '图标形态实例也要入视野（否则全景漏掉缩起的对象）'
  end

  def test_overview_with_empty_desktop_goes_home
    @shell.camera.set(x: 900, y: 400, zoom: 2.0)
    @shell.overview

    assert_equal({ x: 0.0, y: 0.0, zoom: 1.0 }, @shell.camera.get, '空桌面回原点')
  end

  def test_maximize_fits_camera_to_window
    inst = @shell.launch_app(:about)
    @shell.wm.place(:about, { x: 2000, y: 1500, w: 380, h: 280 })

    @shell.send(:window_frame, inst).on_maximize.call

    cam = @shell.camera.get
    refute_equal 1.0, cam[:zoom], 'ZUI 最大化 = 相机 fit 到该窗（D3）'
    sx = (2000 + cam[:x]) * cam[:zoom]
    sy = (1500 + cam[:y]) * cam[:zoom]
    assert sx.between?(0, 1280) && sy.between?(0, 800), '窗口左上角入视野'
  end

  def test_overview_hotkey_registered
    @shell.launch_app(:about)
    @shell.camera.set(x: 3000, y: 2000, zoom: 0.5)

    assert Emerald.hotkey.dispatch({ key: '0', meta: true }), '⌘0 应命中全景'

    refute_equal 0.5, @shell.camera.get[:zoom], '全景改变取景'
  end

  # ── Z1.5 修订（§3.8 表征互斥 + 槽位恒定，2026-09-16 用户复查）──────

  # 启动器退场（§3.8 修订③）：桌面只留文件图标；应用启动入口 = 启动器应用
  # 槽位数学必须整数化：Float 计数会退化成浮点除法，槽位落到 27.75px 这种
  # 鬼位置（浏览器实证踩坑）
  def test_icon_slot_geometry_integerized
    assert_equal({ x: 16, y: 40, w: 80, h: 69 }, @shell.send(:icon_slot_geometry, 0))
    assert_equal({ x: 16, y: 123, w: 80, h: 69 }, @shell.send(:icon_slot_geometry, 1.0),
                 'Float 计数（1.0）也必须按整数行号排版')
    assert_equal({ x: 110, y: 40, w: 80, h: 69 }, @shell.send(:icon_slot_geometry, 8.0))
  end

  def test_desktop_has_no_app_launchers
    html = render_html
    refute_includes html, 'd-icon-app-about', '未运行应用不占桌面（改由启动器应用承担）'
    refute_includes html, 'd-icon-app-clock'

    inst = @shell.launch_app(:about)
    refute_includes render_html, 'd-icon-app-about', '运行中（窗口形态）也不回到桌面图标'

    @shell.morph_to_icon(inst)
    assert_includes render_html, 'zui-iconform-about',
                    '收起形态才在桌面出现——桌面应用图标 = 该应用正开着'
    @shell.quit_app(:about)
    refute_includes render_html, 'zui-iconform-about', '退出后桌面无残留'
  end

  def test_anchor_slots_are_column_first
    a = @shell.launch_app(:about)
    @shell.stub(:now_ms, 5000) { @shell.launch_app(:files) }
    assert_equal({ x: 16, y: 40, w: 80, h: 69 }, a.icon_geometry, '槽 0')
    b = @shell.registry.each_running.to_a.last
    assert_equal({ x: 16, y: 123, w: 80, h: 69 }, b.icon_geometry, '槽 1（列优先：40 + 83）')

    # about=槽0、files=槽1，再开 7 个时钟补到槽 8（第 9 个槽）→ 换列
    7.times { |i| @shell.stub(:now_ms, 10_000 + i * 1000) { @shell.launch_app(:clock) } }
    ninth = @shell.registry.each_running.to_a.last
    assert_equal({ x: 110, y: 40, w: 80, h: 69 }, ninth.icon_geometry,
                 '槽 8 起换列（x = 16 + 94，行号归 0）')
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
    assert_equal({ x: 16, y: 40, w: 80, h: 69 }, inst.icon_geometry,
                 '锚位在启动时定（槽位恒定不变量）：图标列空槽 0')

    @shell.wm.place(:about, { x: 700, y: 500, w: 380, h: 280 })
    @shell.morph_to_icon(inst)
    assert_equal({ x: 16, y: 40, w: 80, h: 69 }, inst.icon_geometry,
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
