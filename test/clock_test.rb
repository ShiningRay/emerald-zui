# frozen_string_literal: true

require 'minitest/autorun'
require 'emerald/zui'
require 'emerald/zui/apps/clock'

# Z1.5 · 时钟 dogfood 应用单测（docs/PLAN.md §3.8 活图标示例）：
# 契约常量（B 路线按此注册）、指针角度/分钟粒度纯数学、窗口形态（模拟钟面）/
# 图标形态（两根指针）渲染、两形态共享 now signal 的同步走字、boot/deactivate
# 的 tick 生命周期、多实例独立。纯 CRuby（beryl F5）：StringRenderer 渲染 +
# 直接方法断言；分钟 tick 经注入的录制后端断言排程语义，浏览器实际走字归验收。
class ClockTest < Minitest::Test
  Clock = Emerald::Zui::Apps::Clock

  # 图标形态渲染的插槽替身：复刻 shell 的接线方式——在另一个组件的 view
  # 上下文里调用 inst.icon_view（节点 owner 归实例），而非挂载组件本身
  class IconHarness < Citrine::Component
    def initialize(target)
      @target = target
      super()
    end

    def view
      @target.icon_view
    end
  end

  def setup
    @backend_was = Beryl::Timer.backend
    @cancel_was = Beryl::Timer.cancel_backend
  end

  def teardown
    Beryl::Timer.backend = @backend_was
    Beryl::Timer.cancel_backend = @cancel_was
  end

  # ── 契约常量（跨路线锁：态机/shell 按此注册与渲染分发）────────

  def test_manifest_contract
    assert_equal Emerald::App, Clock.superclass
    assert_equal :clock, Clock.app_id
    assert_equal '时钟', Clock.app_title
    refute Clock.singleton, '多实例：验收项「多实例各自独立图标形态」要求非单例'
    assert_equal({ x: 180, y: 120, w: 320, h: 340 }, Clock.default_geometry.call)
  end

  # ── 指针角度与分钟粒度纯数学（纯 CRuby 契约段）────────────────

  def test_hand_angles
    assert_equal({ hour: 0, minute: 0 },
                 Clock.hand_angles(Time.local(2026, 9, 15, 12, 0, 0)))
    assert_equal({ hour: 90, minute: 0 },
                 Clock.hand_angles(Time.local(2026, 9, 15, 15, 0, 0)),
                 '15:00 时针恰指 3')
    assert_equal({ hour: 100, minute: 120 },
                 Clock.hand_angles(Time.local(2026, 9, 15, 15, 20, 0)),
                 '时针随分钟爬行：3×30 + 20×0.5 = 100')
    assert_equal({ hour: 195.0, minute: 180 },
                 Clock.hand_angles(Time.local(2026, 9, 15, 6, 30, 0)))
    assert_equal({ hour: 359.5, minute: 354 },
                 Clock.hand_angles(Time.local(2026, 9, 15, 23, 59, 0)))
    assert_equal({ hour: 0, minute: 0 },
                 Clock.hand_angles(Time.local(2026, 9, 15, 0, 0, 0)))
  end

  def test_snap_truncates_to_minute
    t = Time.local(2026, 9, 15, 14, 35, 42)
    s = Clock.snap(t)
    assert_equal [2026, 9, 15, 14, 35, 0], [s.year, s.mon, s.day, s.hour, s.min, s.sec]
    assert_equal 0, s.usec
    assert_equal Clock.snap(t), Clock.snap(Time.local(2026, 9, 15, 14, 35, 59)),
                 '同一分钟内任意时刻 snap 结果一致（signal 相等短路的前提）'
  end

  def test_ms_until_next_minute
    assert_equal 60_000, Clock.ms_until_next_minute(Time.local(2026, 9, 15, 14, 35, 0))
    assert_equal 45_000, Clock.ms_until_next_minute(Time.local(2026, 9, 15, 14, 35, 15))
    assert_equal 29_500, Clock.ms_until_next_minute(Time.local(2026, 9, 15, 14, 35, 30, 500_000))
    assert_equal 1, Clock.ms_until_next_minute(Time.local(2026, 9, 15, 14, 35, 59, 999_000))
  end

  def test_now_defaults_to_current_minute
    t = Time.now
    inst = Clock.new
    assert_equal 0, inst.now.sec
    # 跨分钟边界时容忍 1 分钟误差：初值应落在 t 与 t+60s 所在的两个分钟之一
    minutes = [Clock.snap(t), Clock.snap(t + 60)].map { |s| [s.hour, s.min] }
    assert_includes minutes, [inst.now.hour, inst.now.min],
                    '未 boot 直渲染也应显示当前分钟（惰性初值）'
  end

  # ── 窗口形态：模拟钟面 ────────────────────────────────

  def test_window_form_renders_analog_face
    html = render_face(Clock.new)
    assert_includes html, 'zui-clock-dial'
    assert_includes html, "width:#{Clock::DIAL_PX}px"
    assert_equal 12, html.scan('zui-clock-tick').size, '模拟钟面应有 12 时刻度'
    assert_equal 2, html.scan(/zui-clock-hand-(?:hour|minute)/).size,
                 '只有时针与分针（秒针不渲染）'
    assert_includes html, 'zui-clock-pin'
  end

  def test_window_hands_rotate_with_now
    inst = Clock.new
    inst.now = Time.local(2026, 9, 15, 15, 20, 0)
    html = render_face(inst)
    hour = html[/zui-clock-hand-hour" style="([^"]*)"/, 1]
    minute = html[/zui-clock-hand-minute" style="([^"]*)"/, 1]
    refute_nil hour
    refute_nil minute
    assert_includes hour, 'rotate(100deg)', '15:20 时针 = 3×30 + 20×0.5'
    assert_includes minute, 'rotate(120deg)', '15:20 分针 = 20×6'
    assert_includes hour, 'transform-origin:50% 100%', '指针绕盘心（底边中点）旋转'
  end

  # ── 图标形态：两根指针（D7 活图标覆写点）──────────────────────

  def test_icon_form_is_two_hands_on_small_dial
    html = render_icon(Clock.new)
    assert_equal 2, html.scan(/zui-clock-hand-(?:hour|minute)/).size,
                 '图标形态 = 两根指针，无秒针'
    refute_includes html, 'zui-clock-tick', '小表盘不渲染刻度'
    assert_includes html, "width:#{Clock::ICON_PX}px"
    assert_includes html, 'zui-clock-dial'
  end

  # ── 活图标核心契约：两形态共享 now signal，同步走字 ──────────────
  # 注意：表盘刻度环本身带 12 个 rotate(30° 步进)，对指针角的断言必须
  # 只落在 zui-clock-hand-* 的样式上（正则提取），不能被刻度干扰。

  def test_icon_and_window_forms_share_the_minute_signal
    inst = Clock.new
    inst.now = Time.local(2026, 9, 15, 15, 20, 0)

    face_hands = hand_styles(render_face(inst))
    icon_hands = hand_styles(render_icon(inst))
    [face_hands, icon_hands].each do |hands|
      assert_equal 2, hands.size
      assert_includes hands.join, 'rotate(100deg)'
      assert_includes hands.join, 'rotate(120deg)'
    end

    # 走字：signal 翻转后两形态一起更新（同一实例、同一批 state，PLAN §3.8）
    inst.now = Time.local(2026, 9, 15, 15, 21, 0)
    face_hands = hand_styles(render_face(inst))
    icon_hands = hand_styles(render_icon(inst))
    [face_hands, icon_hands].each do |hands|
      refute_includes hands.join, 'rotate(120deg)', '旧分钟的分针角应消失'
      assert_includes hands.join, 'rotate(100.5deg)', '15:21 时针 = 3×30 + 21×0.5'
      assert_includes hands.join, 'rotate(126deg)', '15:21 分针 = 21×6'
    end
  end

  def test_multi_instance_have_independent_now
    a = Clock.new
    b = Clock.new
    a.now = Time.local(2026, 9, 15, 8, 0, 0)
    b.now = Time.local(2026, 9, 15, 20, 30, 0)

    assert_includes hand_styles(render_face(a)).join, 'rotate(240deg)',
                    'a：8:00 时针 = 8×30 = 240'
    assert_includes hand_styles(render_icon(a)).join, 'rotate(240deg)'
    refute_includes hand_styles(render_face(b)).join, 'rotate(240deg)'
    assert_includes hand_styles(render_face(b)).join, 'rotate(180deg)',
                    'b：20:30 分针 = 30×6 = 180'
    assert_equal 0, a.now.min
    assert_equal 30, b.now.min, '两实例 state signal 互不染'
  end

  # ── 生命周期：boot 起表 / deactivate 停表（分钟粒度排程）────────

  def test_boot_starts_minute_tick_chain_and_deactivate_stops
    calls = []
    cancels = []
    Beryl::Timer.backend = ->(ms, blk) { calls << [ms, blk]; "handle-#{calls.size}" }
    Beryl::Timer.cancel_backend = ->(h) { cancels << h }

    inst = Clock.new
    inst.boot({})

    assert_equal 0, inst.now.sec, 'boot 即对表（分钟粒度）'
    assert_equal 1, calls.size
    assert_operator calls[0][0], :>=, 0
    assert_operator calls[0][0], :<=, 60_000, '首次排程落在当前这一分钟内'

    before = Time.now
    calls[0][1].call # 模拟到点
    after = Time.now
    assert_equal 0, inst.now.sec, '每次 tick 都对齐分钟边界'
    assert_equal 2, calls.size, 'tick 内重排（Beryl::Timer 一次性语义）'
    # 重排延迟 = 到下一分钟边界的毫秒数：浏览器里定时器到点触发、相位 ≈ 0，
    # 连续延迟 ≈ 60s；测试手动调用相位任意，故钉「与调用时刻相位一致」语义
    # （相位随时间递减：f(after) ≤ 延迟 ≤ f(before)，±1ms 吸收取整）
    assert_operator calls[1][0], :<=, Clock.ms_until_next_minute(before) + 1
    assert_operator calls[1][0], :>=, Clock.ms_until_next_minute(after) - 1
    assert_operator calls[1][0], :>, 0
    assert_operator calls[1][0], :<=, 60_000

    inst.deactivate
    assert_equal ['handle-2'], cancels, 'deactivate 取消未执行的 tick'
  end

  def test_deactivate_is_safe_without_boot_and_idempotent
    # 关闭链路（wm.close + registry.dispose）对未启动/已停表的实例都必须无害：
    # 形态态机 window→icon 只 wm.close 不 dispose，deactivate 仅在真正销毁时到达
    Beryl::Timer.backend = ->(_ms, _blk) { 'h' }
    Beryl::Timer.cancel_backend = ->(_h) {}

    inst = Clock.new
    assert_nil inst.deactivate, '未 boot（@timer 为 nil）停表是 no-op'

    inst.boot({})
    inst.deactivate
    inst.deactivate
    assert_nil inst.instance_variable_get(:@timer)
  end

  private

  def render_face(inst)
    Citrine.render(inst)
  end

  def render_icon(inst)
    Citrine.render(IconHarness.new(inst))
  end

  # 只提取两根指针的样式串（刻度环也带 rotate，全 html 断言会被干扰）
  def hand_styles(html)
    html.scan(/zui-clock-hand-(?:hour|minute)" style="([^"]*)"/).flatten
  end
end
