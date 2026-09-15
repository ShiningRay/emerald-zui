# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald/zui/morph'

# 形变引擎纯数学段契约锁定（docs/PLAN.md §3.9）：transform(from, to) 的
# 中心差 translate + 非均匀 scale 数学、数值格式化、退化矩形防御；
# fly 的 CRuby 兜底（直接 on_done，SSR/单测语义）。Opal 执行段（克隆/
# transitionend/兜底定时器/防重入）是浏览器侧行为，单测天然盲区
# （PLAN §9 方法论记录），由示例页 CSS 段与浏览器验收覆盖。
# 只加载 morph 本体（不经 emerald/zui 入口），与 shell/app_form 等
# 并行工序解耦（projector_test 同款纪律）。
class MorphTest < Minitest::Test
  M = Emerald::Zui::Morph

  # ── 常量 ─────────────────────────────────────────────

  def test_duration_constant
    assert_equal 320, M::DURATION_MS
  end

  # ── transform：中心差 translate + 非均匀 scale ────────

  def test_identity_rects
    assert_equal 'translate(0px, 0px) scale(1, 1)',
                 M.transform({ x: 10, y: 20, w: 100, h: 80 },
                             { x: 10, y: 20, w: 100, h: 80 })
  end

  def test_pure_translation_same_size
    # 等大平移：中心 (50,50) → (100,130)，scale 恒 1
    assert_equal 'translate(50px, 80px) scale(1, 1)',
                 M.transform({ x: 0, y: 0, w: 100, h: 100 },
                             { x: 50, y: 80, w: 100, h: 100 })
  end

  def test_pure_scale_same_center
    # 同心放大 2×：中心差为 0，只走 scale
    assert_equal 'translate(0px, 0px) scale(2, 2)',
                 M.transform({ x: 0, y: 0, w: 100, h: 100 },
                             { x: -50, y: -50, w: 200, h: 200 })
  end

  def test_combined_translate_and_non_uniform_scale
    # 窗口 200×100 @ (100,100) → 图标 50×200 @ (400,700)
    # 中心 (200,150) → (425,800)：translate(225, 650)；scale 0.25 / 2
    assert_equal 'translate(225px, 650px) scale(0.25, 2)',
                 M.transform({ x: 100, y: 100, w: 200, h: 100 },
                             { x: 400, y: 700, w: 50, h: 200 })
  end

  def test_window_to_icon_fixture
    # 手算夹具：窗口 640×480 @ (200,120)（中心 520,360）→ 图标 96×96 @
    # (48,900)（中心 96,948）：translate(-424, 588)、scale 0.15 / 0.2
    assert_equal 'translate(-424px, 588px) scale(0.15, 0.2)',
                 M.transform({ x: 200, y: 120, w: 640, h: 480 },
                             { x: 48, y: 900, w: 96, h: 96 })
  end

  def test_float_inputs_are_normalized
    # 浮点输入：像素两位小数、比率四位，尾随零去净（0.3333… → 0.3333）
    t = M.transform({ x: 0.0, y: 0.0, w: 300.0, h: 300.0 },
                    { x: 100.25, y: 50.5, w: 100.0, h: 150.0 })
    assert_equal 'translate(0.25px, -24.5px) scale(0.3333, 0.5)', t
  end

  # ── transform：矩形契约防御 ───────────────────────────

  def test_missing_keys_raise
    err = assert_raises(ArgumentError) do
      M.transform({ x: 0, y: 0, w: 10 }, { x: 0, y: 0, w: 1, h: 1 })
    end
    assert_includes err.message, '缺少键'
    assert_includes err.message, 'h'
  end

  def test_non_positive_size_raises
    assert_raises(ArgumentError) do
      M.transform({ x: 0, y: 0, w: 0, h: 10 }, { x: 0, y: 0, w: 5, h: 5 })
    end
    assert_raises(ArgumentError) do
      M.transform({ x: 0, y: 0, w: 10, h: -2 }, { x: 0, y: 0, w: 5, h: 5 })
    end
  end

  # ── fly：CRuby 兜底（Opal 执行段归浏览器验收）─────────

  def test_cruby_fly_calls_done_immediately
    called = []
    M.fly(nil, nil,
          { x: 0, y: 0, w: 100, h: 100 }, { x: 50, y: 80, w: 96, h: 96 },
          -> { called << :done })
    assert_equal [:done], called, 'CRuby/SSR 不起动画，同步收场（渲染目标形态）'
  end

  def test_cruby_fly_returns_done_value
    assert_equal :ok, M.fly(nil, nil, nil, nil, -> { :ok })
  end

  def test_not_morphing_by_default
    refute M.morphing?, 'CRuby 下不起动画，防重入标志恒 false'
  end
end
