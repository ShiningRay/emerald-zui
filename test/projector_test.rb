# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald/zui/projector'

# 小地图投影器全契约锁定（PLAN §8 防迷路三件套之一）：
# 等比缩放取短轴 / 居中留白 / 世界↔像素双向逆映射 / 退化包围盒按 1 算 /
# 窗口矩形 union。只加载 projector 本体（不经 emerald/zui 入口），
# 与 shell/minimap 等并行工序解耦。
class ProjectorTest < Minitest::Test
  DELTA = 1e-9

  # 主夹具：世界 1000×500（2:1 宽），小地图 200×200 方盒、padding 8
  #   s = min(184/1000, 184/500) = 0.184（宽轴受限）
  #   映射后 184×92，居中：origin = (8, 54)
  BOUNDS = { x: 0, y: 0, w: 1000, h: 500 }.freeze
  BOX = { w: 200, h: 200 }.freeze

  def projector(**opts)
    Emerald::Zui::Projector.new(bounds: BOUNDS, box: BOX, **opts)
  end

  # ── 常量 / 初始化 ────────────────────────────────────

  def test_default_padding
    assert_equal 8, Emerald::Zui::Projector::DEFAULT_PADDING
    assert_in_delta 0.184, projector.scale, DELTA
    assert_in_delta 0.184, projector(padding: 8).scale, DELTA
  end

  def test_scale_takes_min_of_both_axes
    assert_in_delta 0.184, projector.scale, DELTA

    # 高世界（1:2.5）：高轴受限，s = 184/1000
    tall = Emerald::Zui::Projector.new(bounds: { x: 0, y: 0, w: 400, h: 1000 }, box: BOX)
    assert_in_delta 0.184, tall.scale, DELTA

    # padding 收缩可用区域：s = min(160/1000, 160/500)
    padded = projector(padding: 20)
    assert_in_delta 0.16, padded.scale, DELTA
  end

  # ── to_map：包围盒四角 / 中心 / 居中留白 ─────────────

  def test_to_map_bounds_corners
    p = projector
    assert_equal [8.0, 54.0], p.to_map(0, 0)
    assert_equal [192.0, 146.0], p.to_map(1000, 500)
  end

  def test_to_map_bounds_center_is_box_center
    p = projector
    assert_equal [100.0, 100.0], p.to_map(500, 250)
  end

  def test_to_map_limiting_axis_spans_exact_inset
    p = projector
    left = p.to_map(0, 250)[0]
    right = p.to_map(1000, 250)[0]
    assert_in_delta BOX[:w] - 16.0, right - left, DELTA # 受限轴恰好 = box.w − 2p
  end

  def test_to_map_short_axis_is_centered
    p = projector
    top = p.to_map(500, 0)[1]
    bottom = p.to_map(500, 500)[1]
    assert_in_delta 54.0, top, DELTA  # (200 − 92)/2：短轴留白上下对称
    assert_in_delta 146.0, bottom, DELTA
    assert_in_delta (top + bottom) / 2.0, 100.0, DELTA # 映射后包围盒中心 = 盒中心
  end

  def test_to_map_offset_by_bounds_origin
    p = Emerald::Zui::Projector.new(bounds: { x: 100, y: 200, w: 1000, h: 500 }, box: BOX)
    assert_equal [8.0, 54.0], p.to_map(100, 200) # bounds 原点 → 映射原点
    assert_equal [192.0, 146.0], p.to_map(1100, 700)
  end

  # ── to_world：逆映射 / 往返恒等 ─────────────────────

  def test_to_world_inverts_to_map
    p = projector
    assert_equal [0.0, 0.0], p.to_world(8, 54)
    assert_equal [1000.0, 500.0], p.to_world(192, 146)
    assert_equal [500.0, 250.0], p.to_world(100, 100)
  end

  def test_map_world_round_trip
    fixtures = [
      [BOUNDS, BOX, 8],
      [{ x: 100, y: 200, w: 1000, h: 500 }, BOX, 8],
      [{ x: -300, y: -700, w: 2000, h: 1500 }, { w: 180, h: 120 }, 6],
      [{ x: 0, y: 0, w: 400, h: 1000 }, BOX, 8] # 高轴受限
    ]
    points = [[0.0, 0.0], [123.5, 300.25], [999.0, 12.0]]

    fixtures.each do |bounds, box, padding|
      p = Emerald::Zui::Projector.new(bounds: bounds, box: box, padding: padding)
      points.each do |wx, wy|
        mapped = p.to_map(wx, wy)
        back = p.to_world(*mapped)
        assert_in_delta wx, back[0], 1e-6, "bounds=#{bounds} (#{wx},#{wy})"
        assert_in_delta wy, back[1], 1e-6, "bounds=#{bounds} (#{wx},#{wy})"

        unmapped = p.to_world(wx, wy)
        forth = p.to_map(*unmapped)
        assert_in_delta wx, forth[0], 1e-6, "box=#{box} (#{wx},#{wy})"
        assert_in_delta wy, forth[1], 1e-6, "box=#{box} (#{wx},#{wy})"
      end
    end
  end

  # ── 退化包围盒：w/h ≤ 0 按 1 算 ─────────────────────

  def test_degenerate_bounds_treated_as_one
    p = Emerald::Zui::Projector.new(bounds: { x: 100, y: 200, w: 0, h: -5 },
                                    box: { w: 100, h: 60 }, padding: 8)
    assert_in_delta 44.0, p.scale, DELTA # min(84/1, 44/1)——高轴受限，不除零
    assert_equal [28.0, 8.0], p.to_map(100, 200)
    assert_equal [100.0, 200.0], p.to_world(28, 8) # 往返仍成立

    zero_w = Emerald::Zui::Projector.new(bounds: { x: 0, y: 0, w: 0, h: 500 }, box: BOX)
    assert_in_delta 0.368, zero_w.scale, DELTA # min(184/1, 184/500)——高轴受限
  end

  # ── union：窗口矩形并集 ─────────────────────────────

  def test_union_empty_is_zero_rect
    assert_equal({ x: 0, y: 0, w: 0, h: 0 }, Emerald::Zui::Projector.union([]))
  end

  def test_union_single_rect
    assert_equal({ x: 10.0, y: 20.0, w: 300.0, h: 200.0 },
                 Emerald::Zui::Projector.union([{ x: 10, y: 20, w: 300, h: 200 }]))
  end

  def test_union_spans_min_max
    rects = [
      { x: 0, y: 0, w: 100, h: 50 },
      { x: 50, y: -20, w: 200, h: 80 },
      { x: -30, y: 10, w: 20, h: 20 }
    ]
    assert_equal({ x: -30.0, y: -20.0, w: 280.0, h: 80.0 },
                 Emerald::Zui::Projector.union(rects))
  end

  def test_union_returns_floats
    result = Emerald::Zui::Projector.union([{ x: 1, y: 2, w: 3, h: 4 }])
    assert result.values.all? { |v| v.is_a?(Float) }
  end

  def test_union_empty_result_wired_as_bounds_is_safe
    # 空桌面：union 零矩形直接喂 Projector 不炸（退化按 1 算，调用方兜底缩放）
    p = Emerald::Zui::Projector.new(bounds: Emerald::Zui::Projector.union([]), box: BOX)
    assert p.scale.positive?
    assert_equal [8.0, 8.0], p.to_map(0, 0) # 单点放大居中
  end
end
