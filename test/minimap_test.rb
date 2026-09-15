# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald/zui'

# Z1 · 小地图单测（docs/PLAN.md §8 防迷路三件套之一）：投影接线（窗块/取景框
# 几何）、导航纯逻辑段（地图坐标/客户端坐标 → Camera#center_on）、active 高亮。
# 纯 CRuby（beryl F5）：StringRenderer 渲染 + 直接方法断言；投影数学本身的
# 断言归 projector_test（契约边界），点击/拖拽的 DOM 监听段由浏览器验收。
class MinimapTest < Minitest::Test
  VP = { w: 1000, h: 600 }.freeze

  def setup
    @camera = Emerald::Zui::Camera.new
    @wm = Beryl::WindowManager.new(viewport: nil)
    @minimap = Emerald::Zui::Minimap.new(wm: @wm, camera: @camera,
                                         viewport: -> { VP })
  end

  def render_html
    Citrine.render(@minimap)
  end

  # ── 渲染结构 ─────────────────────────────────────────

  def test_renders_canvas_and_camera_rect_even_with_no_windows
    html = render_html
    assert_includes html, 'zui-minimap'
    assert_includes html, 'zui-minimap-canvas'
    assert_includes html, 'zui-minimap-cam', '空世界也应有相机取景框（防迷路底线）'
    refute_includes html, 'zui-minimap-win'
  end

  def test_window_blip_projects_onto_map
    @wm.open(:a, title: 'A', geometry: { x: 100, y: 50, w: 400, h: 300 })
    html = render_html

    blip = html[/class="zui-minimap-win[^"]*" style="([^"]*)"/, 1]
    refute_nil blip, '窗口应渲染出地图色块'
    # 手算钉死：bounds = union(窗口, 取景框{0,0,1000,600}) = {0,0,1000,600}，
    # s = min(164/1000, 104/600) = 0.164，短轴居中 oy = (120−98.4)/2 = 10.8
    assert_in_delta 24.4, style_num(blip, :left), 1e-6   # 100×0.164 + 8
    assert_in_delta 19.0, style_num(blip, :top), 1e-6    # 50×0.164 + 10.8
    assert_in_delta 65.6, style_num(blip, :width), 1e-6  # 400×0.164
    assert_in_delta 49.2, style_num(blip, :height), 1e-6 # 300×0.164
  end

  def test_camera_rect_reflects_viewport_at_zoom_one
    style = render_html[/class="zui-minimap-cam" style="([^"]*)"/, 1]
    refute_nil style
    # 手算钉死：bounds 即取景框本身 → 映射后恰好 = box 去 padding
    assert_in_delta 8.0, style_num(style, :left), 1e-6    # (180−164)/2
    assert_in_delta 10.8, style_num(style, :top), 1e-6    # (120−98.4)/2
    assert_in_delta 164.0, style_num(style, :width), 1e-6  # 1000×0.164
    assert_in_delta 98.4, style_num(style, :height), 1e-6  # 600×0.164
  end

  def test_camera_rect_stays_inside_map_at_any_zoom
    # 防迷路语义核心：bounds 恒包含取景框 → 任何相机状态取景框都不出图
    [{ x: 0, y: 0, zoom: 1.0 }, { x: 500, y: -300, zoom: 2.5 },
     { x: -8000, y: 6000, zoom: 0.1 }, { x: 123.5, y: 45.25, zoom: 4.0 }].each do |st|
      @camera.set(st)
      style = render_html[/class="zui-minimap-cam" style="([^"]*)"/, 1]
      left = style_num(style, :left)
      top = style_num(style, :top)
      right = left + style_num(style, :width)
      bottom = top + style_num(style, :height)
      assert_operator left, :>=, 0.0, "state=#{st} 取景框出图左界"
      assert_operator top, :>=, 0.0, "state=#{st} 取景框出图上界"
      assert_operator right, :<=, Emerald::Zui::Minimap::BOX_W, "state=#{st} 取景框出图右界"
      assert_operator bottom, :<=, Emerald::Zui::Minimap::BOX_H, "state=#{st} 取景框出图下界"
    end
  end

  def test_blip_highlights_active_window
    @wm.open(:a, title: 'A', geometry: { x: 0, y: 0, w: 200, h: 100 })
    @wm.open(:b, title: 'B', geometry: { x: 300, y: 0, w: 200, h: 100 })
    @wm.focus(:a)

    html = render_html
    assert_includes html, 'zui-minimap-win is-active'
    assert_equal 1, html.scan('zui-minimap-win is-active').size, '仅激活窗口高亮'
    assert_equal 2, html.scan('zui-minimap-win').size
  end

  def test_moving_window_moves_blip
    @wm.open(:a, title: 'A', geometry: { x: 0, y: 0, w: 200, h: 100 })
    before = style_num(render_html[/class="zui-minimap-win[^"]*" style="([^"]*)"/, 1], :left)
    @wm.move(:a, 400, 0)
    after = style_num(render_html[/class="zui-minimap-win[^"]*" style="([^"]*)"/, 1], :left)
    assert_operator after, :>, before, '拖窗后色块应随世界坐标右移'
  end

  # ── 导航（点击/拖拽 = 相机保持缩放飞到该世界点）──────────

  def test_fly_to_map_point_centers_world_point_keeping_zoom
    @camera.set(x: 7, y: -3, zoom: 2.0)
    @wm.open(:a, title: 'A', geometry: { x: 100, y: 50, w: 400, h: 300 })

    # 飞之前先取该地图点对应的世界坐标（bounds 随飞行变化，须先钉住）
    proj = @minimap.send(:projector)
    wx, wy = proj.to_world(90, 60) # 点击地图中心
    @minimap.send(:fly_to_map_point, 90, 60)

    assert_in_delta 2.0, @camera.get[:zoom], 1e-9, 'center_on 保持缩放'
    screen = @camera.world_to_screen(wx, wy)
    assert_in_delta VP[:w] / 2.0, screen[0], 1e-6, '世界点落在视口中心'
    assert_in_delta VP[:h] / 2.0, screen[1], 1e-6
  end

  def test_fly_to_client_point_subtracts_canvas_origin
    # 画布固定在屏幕右下角附近：客户端坐标须先减画布原点才是地图坐标
    proj = @minimap.send(:projector) # 无窗口：bounds = 取景框 {0,0,1000,600}
    wx, wy = proj.to_world(10, 40)
    @minimap.send(:fly_to_client_point, 200, 700, { left: 190, top: 660 })

    screen = @camera.world_to_screen(wx, wy)
    assert_in_delta VP[:w] / 2.0, screen[0], 1e-6
    assert_in_delta VP[:h] / 2.0, screen[1], 1e-6
  end

  def test_default_viewport_for_cruby
    minimap = Emerald::Zui::Minimap.new(wm: @wm, camera: @camera)
    assert_equal Emerald::Zui::Minimap::DEFAULT_VIEWPORT,
                 minimap.send(:current_viewport)
  end

  private

  # 从 StringRenderer 的内联样式串里取数值（"left:24.4px" → 24.4）
  def style_num(style, key)
    style[/#{key}:([-\d.]+)px/, 1].to_f
  end
end
