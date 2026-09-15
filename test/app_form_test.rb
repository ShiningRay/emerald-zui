# frozen_string_literal: true

# Z1.5 · 形态态机单测（docs/PLAN.md §3.8）：AppForm 实例侧纯状态段——
# form 默认/切换守卫、两套几何簿记（backup 一次性消费、icon_geometry
# 驻留记忆）、级联驻留位纯函数。副作用段（wm/DOM/形变/tile 渲染）归
# shell_test；icon_view 默认渲染的集成断言也在 shell_test（经整机 html）。
require 'minitest/autorun'
require 'emerald/zui'

class AppFormTest < Minitest::Test
  # 形态假人：只承载状态机断言，不启动不开窗
  FormDummy = Class.new(Emerald::App) do
    app_id :form_dummy
    app_title '形态假人'
    app_icon '✱'

    def view
      label { 'dummy' }
    end
  end

  def setup
    @inst = FormDummy.new
  end

  def test_appform_included_into_app
    assert_kind_of Emerald::Zui::AppForm, @inst
  end

  def test_form_defaults_window
    assert_equal :window, @inst.form
  end

  def test_morph_to_icon_backs_up_window_geometry
    geom = { x: 10, y: 20, w: 300, h: 200 }
    assert_nil @inst.morph_to(:icon, window_geometry: geom)
    assert_equal :icon, @inst.form
    assert_equal geom, @inst.window_geometry_backup, '缩起暂存窗口几何（供还原）'
  end

  def test_morph_to_window_consumes_backup_once
    geom = { x: 10, y: 20, w: 300, h: 200 }
    @inst.morph_to(:icon, window_geometry: geom)
    assert_equal geom, @inst.morph_to(:window), '恢复几何 = backup（§3.8 几何还原）'
    assert_equal :window, @inst.form
    assert_nil @inst.window_geometry_backup, 'backup 一次性消费（缩起时暂存语义）'
    assert_nil @inst.morph_to(:window)
    assert_nil @inst.window_geometry_backup
  end

  def test_morph_to_window_without_backup_returns_nil_for_cascade
    @inst.morph_to(:icon)
    assert_nil @inst.morph_to(:window), '无备份 → nil，调用方走级联兜底（§3.8）'
    assert_equal :window, @inst.form
  end

  def test_morph_to_same_form_is_noop
    assert_nil @inst.morph_to(:window), '幂等：重复触发安全'
    @inst.morph_to(:icon, window_geometry: { x: 0, y: 0, w: 1, h: 1 })
    assert_nil @inst.morph_to(:icon, window_geometry: { x: 9, y: 9, w: 9, h: 9 })
    assert_equal :icon, @inst.form
    assert_equal({ x: 0, y: 0, w: 1, h: 1 }, @inst.window_geometry_backup,
                 'no-op 不覆盖已暂存几何')
  end

  def test_morph_to_rejects_invalid_form
    assert_raises(ArgumentError) { @inst.morph_to(:minimized) }
    assert_equal :window, @inst.form, '非法形态不触发任何状态变更'
  end

  def test_icon_geometry_accessor
    assert_nil @inst.icon_geometry
    @inst.icon_geometry = { x: 5, y: 6 }
    assert_equal({ x: 5, y: 6 }, @inst.icon_geometry)
  end

  def test_icon_slot_cascades_from_base
    assert_equal({ x: 100, y: 80 }, Emerald::Zui::AppForm.icon_slot({ x: 100, y: 80 }, 0))
    assert_equal({ x: 148, y: 128 }, Emerald::Zui::AppForm.icon_slot({ x: 100, y: 80 }, 2),
                 '级联缺省：seq × 步长逐个错开（同位叠死的窗口各得其所）')
  end
end
