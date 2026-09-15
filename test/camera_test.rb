# frozen_string_literal: true

require 'minitest/autorun'
require 'citrine'
require 'emerald/zui/camera'

# Z0 · 相机数学全契约锁定（docs/PLAN.md §3.1）：
# 锚点不动性 / 范围钳制 / fit 中心对齐 / 世界屏幕往返恒等 / F6 守卫。
# 只加载 camera 本体（不经 emerald/zui 入口），与 shell 等并行工序解耦。
class CameraTest < Minitest::Test
  DELTA = 1e-9

  VP = { w: 1000, h: 600 }.freeze

  # ── 常量 / 初始状态 ──────────────────────────────────

  def test_zoom_limits
    assert_equal 0.1, Emerald::Zui::Camera::MIN_ZOOM
    assert_equal 4.0, Emerald::Zui::Camera::MAX_ZOOM
  end

  def test_defaults
    cam = Emerald::Zui::Camera.new
    s = cam.get
    assert_equal %i[x y zoom], s.keys
    assert_equal 0.0, s[:x]
    assert_equal 0.0, s[:y]
    assert_equal 1.0, s[:zoom]
    assert s.values.all? { |v| v.is_a?(Float) }

    assert_equal cam.get, Emerald::Zui::Camera.new(nil).get
  end

  def test_initial_state_merges_over_defaults_and_clamps
    assert_equal({ x: 0.0, y: 0.0, zoom: 2.0 }, Emerald::Zui::Camera.new(zoom: 2).get)
    assert_equal({ x: 3.0, y: -4.0, zoom: 4.0 }, Emerald::Zui::Camera.new(x: 3, y: -4, zoom: 99).get)
    assert_equal(0.1, Emerald::Zui::Camera.new(zoom: 0.01).get[:zoom])
  end

  def test_get_returns_fresh_hash
    cam = Emerald::Zui::Camera.new
    snapshot = cam.get
    snapshot[:x] = 999
    snapshot[:zoom] = 999

    fresh = cam.get
    refute_same snapshot, fresh
    assert_equal 0.0, fresh[:x]
    assert_equal 1.0, fresh[:zoom]
  end

  def test_signal_exposure
    cam = Emerald::Zui::Camera.new
    assert_kind_of Citrine::Signal, cam.signal
  end

  # ── set ──────────────────────────────────────────────

  def test_set_replaces_whole_state_and_clamps
    cam = Emerald::Zui::Camera.new
    cam.set(x: 10, y: 20, zoom: 2)
    assert_equal({ x: 10.0, y: 20.0, zoom: 2.0 }, cam.get)

    cam.set(x: 1, y: 1, zoom: 100)
    assert_equal({ x: 1.0, y: 1.0, zoom: 4.0 }, cam.get)

    cam.set(x: 1, y: 1, zoom: 0)
    assert_equal({ x: 1.0, y: 1.0, zoom: 0.1 }, cam.get)
  end

  def test_set_requires_all_keys
    cam = Emerald::Zui::Camera.new
    assert_raises(ArgumentError) { cam.set(x: 1, y: 2) }
    assert_raises(ArgumentError) { cam.set(zoom: 2) }
    assert_equal 0.0, cam.get[:x] # 守卫先于写入，状态未被触碰
  end

  # ── F6 守卫：变更只能从事件回调进入 ──────────────────

  def test_mutations_raise_inside_effect
    cam = Emerald::Zui::Camera.new
    {
      set:      -> { cam.set(x: 0, y: 0, zoom: 1) },
      zoom_at:  -> { cam.zoom_at(0, 0, 2) },
      pan_by:   -> { cam.pan_by(1, 1) },
      fit:      -> { cam.fit({ x: 0, y: 0, w: 10, h: 10 }, VP) }
    }.each do |op, callable|
      error = capture_error_in_effect(&callable)
      refute_nil error, "Camera##{op} 在 Effect 内应 raise"
      assert_match(/Camera##{op}/, error.message)
    end
    assert_equal 0.0, cam.get[:x] # 全部未写入
  end

  # ── zoom_at：锚点不动性 ──────────────────────────────

  def test_zoom_at_formula
    cam = Emerald::Zui::Camera.new
    cam.zoom_at(100, 50, 2)
    assert_equal({ x: -50.0, y: -25.0, zoom: 2.0 }, cam.get)

    cam.zoom_at(100, 50, 0.5) # 反方向缩回，状态精确还原
    assert_equal({ x: 0.0, y: 0.0, zoom: 1.0 }, cam.get)
  end

  def test_zoom_at_keeps_anchor_world_point_on_screen
    states = [
      { x: 0.0, y: 0.0, zoom: 1.0 },
      { x: 120.0, y: -45.0, zoom: 2.5 },
      { x: -300.5, y: 88.25, zoom: 0.75 }
    ]
    points = [[0, 0], [123.5, 456.25], [999.0, 12.0]]

    states.each do |st|
      [1.25, 0.8, 2.0, 0.5, 1.0].each do |factor|
        points.each do |sx, sy|
          cam = Emerald::Zui::Camera.new(st)
          anchor = cam.screen_to_world(sx, sy) # 锚点下的世界坐标
          cam.zoom_at(sx, sy, factor)
          back = cam.world_to_screen(*anchor)
          assert_in_delta sx, back[0], 1e-6, "state=#{st} f=#{factor} 锚点(#{sx},#{sy})"
          assert_in_delta sy, back[1], 1e-6, "state=#{st} f=#{factor} 锚点(#{sx},#{sy})"
        end
      end
    end
  end

  def test_zoom_at_clamps_and_saturation_is_stable
    # 上限饱和：z' == zoom 时 x' == x，整个状态不动（也不广播）
    cam = Emerald::Zui::Camera.new(x: 10, y: 20, zoom: 4)
    cam.zoom_at(300, 200, 2)
    assert_equal({ x: 10.0, y: 20.0, zoom: 4.0 }, cam.get)

    # 下限饱和同理
    cam = Emerald::Zui::Camera.new(zoom: 0.1)
    cam.zoom_at(50, 60, 0.5)
    assert_equal 0.1, cam.get[:zoom]

    # 命中钳制但未饱和：锚点不动性依然成立
    cam = Emerald::Zui::Camera.new(x: 7, y: -3, zoom: 3.5)
    anchor = cam.screen_to_world(200, 100)
    cam.zoom_at(200, 100, 2) # 3.5*2 = 7 → clamp 4
    assert_equal 4.0, cam.get[:zoom]
    back = cam.world_to_screen(*anchor)
    assert_in_delta 200, back[0], 1e-6
    assert_in_delta 100, back[1], 1e-6

    cam = Emerald::Zui::Camera.new(zoom: 0.12)
    anchor = cam.screen_to_world(50, 60)
    cam.zoom_at(50, 60, 0.5) # 0.06 → clamp 0.1
    assert_equal 0.1, cam.get[:zoom]
    back = cam.world_to_screen(*anchor)
    assert_in_delta 50, back[0], 1e-6
    assert_in_delta 60, back[1], 1e-6
  end

  # ── pan_by ───────────────────────────────────────────

  def test_pan_by_formula
    cam = Emerald::Zui::Camera.new
    cam.pan_by(10, 20)
    assert_equal({ x: 10.0, y: 20.0, zoom: 1.0 }, cam.get)

    cam = Emerald::Zui::Camera.new(zoom: 2)
    cam.pan_by(10, 20)
    assert_equal({ x: 5.0, y: 10.0, zoom: 2.0 }, cam.get)
  end

  def test_pan_content_follows_cursor
    cam = Emerald::Zui::Camera.new(x: 5, y: 7, zoom: 2.5)
    before = cam.screen_to_world(320, 240)

    # 抓取语义：按住 (320,240) 下的世界点拖到 (320+30, 240−20)，
    # 该点应跟随光标——缩放前后「光标位置 ↔ 世界点」对应关系不变
    cam.pan_by(30, -20) # 光标向右 30、向上 20：内容同向移动
    after = cam.screen_to_world(320 + 30, 240 - 20)
    assert_in_delta before[0], after[0], DELTA
    assert_in_delta before[1], after[1], DELTA

    # 反例锁定：原位置现在指向的是别的世界点（内容确实移动了）
    assert_operator (cam.screen_to_world(320, 240)[0] - before[0]).abs, :>, 1.0
  end

  # ── fit ──────────────────────────────────────────────

  def test_fit_centers_rect_in_viewport
    cam = Emerald::Zui::Camera.new
    cam.fit({ x: 100, y: 50, w: 400, h: 200 }, VP)

    assert_in_delta 2.3, cam.get[:zoom], DELTA # min(920/400, 520/200)
    assert_in_delta(-82.6086956521739, cam.get[:x], 1e-6)
    assert_in_delta(-19.565217391304348, cam.get[:y], 1e-6)

    # 矩形中心 → 视口中心（锁定恒等式 screen = (world + cam)*zoom）
    center = cam.world_to_screen(300, 150)
    assert_in_delta 500.0, center[0], 1e-6
    assert_in_delta 300.0, center[1], 1e-6

    # 受限轴（宽）恰好落在 padding 上，另一轴留白
    tl = cam.world_to_screen(100, 50)
    br = cam.world_to_screen(500, 250)
    assert_in_delta 40.0, tl[0], 1e-6
    assert_in_delta 960.0, br[0], 1e-6
    assert_operator tl[1], :>=, 40.0
    assert_operator br[1], :<=, 560.0
  end

  def test_fit_clamps_to_max_and_min
    cam = Emerald::Zui::Camera.new
    cam.fit({ x: 0, y: 0, w: 10, h: 10 }, VP) # min(92, 52) → 52 → clamp 4
    assert_in_delta 4.0, cam.get[:zoom], DELTA
    center = cam.world_to_screen(5, 5)
    assert_in_delta 500.0, center[0], 1e-6
    assert_in_delta 300.0, center[1], 1e-6

    cam = Emerald::Zui::Camera.new
    cam.fit({ x: -5000, y: -5000, w: 20_000, h: 20_000 }, VP) # → 0.026 → clamp 0.1
    assert_in_delta 0.1, cam.get[:zoom], DELTA
    center = cam.world_to_screen(5000, 5000)
    assert_in_delta 500.0, center[0], 1e-6
    assert_in_delta 300.0, center[1], 1e-6
  end

  def test_fit_with_zero_padding
    cam = Emerald::Zui::Camera.new
    cam.fit({ x: 0, y: 0, w: 400, h: 200 }, VP, padding: 0)
    assert_in_delta 2.5, cam.get[:zoom], DELTA # min(1000/400, 600/200)
    center = cam.world_to_screen(200, 100)
    assert_in_delta 500.0, center[0], 1e-6
    assert_in_delta 300.0, center[1], 1e-6
  end

  def test_fit_degenerate_rect_keeps_zoom_and_centers
    cam = Emerald::Zui::Camera.new(zoom: 1.5)
    cam.fit({ x: 300, y: 150, w: 0, h: 0 }, { w: 800, h: 600 })
    assert_equal 1.5, cam.get[:zoom] # 无有效面积，不改缩放
    center = cam.world_to_screen(300, 150)
    assert_in_delta 400.0, center[0], 1e-6
    assert_in_delta 300.0, center[1], 1e-6

    cam.fit({ x: 10, y: 10, w: 100, h: -5 }, VP) # 负高同一路径
    assert_equal 1.5, cam.get[:zoom]
  end

  def test_fit_degenerate_viewport_does_not_crash
    cam = Emerald::Zui::Camera.new
    cam.fit({ x: 0, y: 0, w: 100, h: 100 }, { w: 0, h: 600 })
    assert_equal 1.0, cam.get[:zoom]
  end

  # ── 世界/屏幕换算 ────────────────────────────────────

  def test_world_to_screen_formula
    cam = Emerald::Zui::Camera.new(x: 5, y: 5, zoom: 2)
    assert_equal [30.0, 50.0], cam.world_to_screen(10, 20)
    assert_equal [10.0, 20.0], Emerald::Zui::Camera.new.world_to_screen(10, 20)
  end

  def test_screen_to_world_formula
    cam = Emerald::Zui::Camera.new(x: 5, y: 5, zoom: 2)
    assert_equal [10.0, 20.0], cam.screen_to_world(30, 50)
    assert_equal [10.0, 20.0], Emerald::Zui::Camera.new.screen_to_world(10, 20)
  end

  def test_world_screen_round_trip
    states = [
      { x: 0.0, y: 0.0, zoom: 1.0 },
      { x: 5.0, y: 5.0, zoom: 2.0 },
      { x: -33.3333, y: 50.0, zoom: 1.5 },
      { x: 120.0, y: -45.0, zoom: 0.1 }
    ]
    points = [[0.0, 0.0], [10.5, -20.25], [1234.0, 567.0]]

    states.each do |st|
      cam = Emerald::Zui::Camera.new(st)
      points.each do |px, py|
        s = cam.world_to_screen(px, py)
        w = cam.screen_to_world(*s)
        assert_in_delta px, w[0], 1e-6, "round trip screen->world #{st} (#{px},#{py})"
        assert_in_delta py, w[1], 1e-6, "round trip screen->world #{st} (#{px},#{py})"

        w2 = cam.screen_to_world(px, py)
        s2 = cam.world_to_screen(*w2)
        assert_in_delta px, s2[0], 1e-6, "round trip world->screen #{st} (#{px},#{py})"
        assert_in_delta py, s2[1], 1e-6, "round trip world->screen #{st} (#{px},#{py})"
      end
    end
  end

  # ── Signal 语义：相等写入短路，不广播 ────────────────

  def test_equal_writes_do_not_broadcast
    cam = Emerald::Zui::Camera.new
    runs = 0
    Citrine::Effect.create { cam.signal.get; runs += 1 }

    cam.zoom_at(100, 100, 1.0) # factor 1 → 状态不变
    assert_equal 1, runs
    cam.pan_by(0, 0)
    assert_equal 1, runs

    cam.zoom_at(100, 100, 2.0)
    assert_equal 2, runs
    cam.set(x: 0.0, y: 0.0, zoom: 1.0) # 写回默认，确为变更
    assert_equal 3, runs
    assert_equal 0.0, cam.get[:x]
  end

  private

  # 在 Effect 内执行块并捕获第一个 ArgumentError（beryl window_test 同款模式）
  def capture_error_in_effect
    error = nil
    Citrine::Effect.create do
      begin
        yield
      rescue ArgumentError => e
        error = e
      end
      nil
    end
    error
  end
end
