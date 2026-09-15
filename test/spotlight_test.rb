# frozen_string_literal: true

# 启动器应用（Spotlight 式）单测（docs/PLAN.md §3.8 修订③）：
# 过滤 / 状态判定 / 主操作路由 / 退出 / 键盘导航——纯逻辑段，经假 ctx 注入
# 服务面（launcher + zui 两个 lambda 表），不碰 Opal 与 DOM。
require 'minitest/autorun'
require 'emerald/zui'

class ZuiSpotlightTest < Minitest::Test
  # 假 registry：只实现启动器用到的 apps / each_running / launch
  class FakeRegistry
    attr_reader :launched

    def initialize(apps, running)
      @apps = apps
      @running = running
      @launched = []
    end

    def apps = @apps
    def each_running = @running
    def launch(id) = @launched << id
  end

  # 假实例：启动器只读 class.app_id / win_id / form
  FakeInst = Struct.new(:klass_id, :win_id, :form) do
    def class
      Struct.new(:app_id).new(klass_id)
    end
  end

  APPS = [
    { id: :about,   title: '关于',       icon: '◈' },
    { id: :files,   title: '文件管理器', icon: '🗂️' },
    { id: :clock,   title: '时钟',       icon: '◷' },
  ].freeze

  def setup
    @calls = []
    @running = [FakeInst.new(:files, :files, :window)]
    @registry = FakeRegistry.new(APPS, @running)
    @app = Emerald::Zui::Apps::Spotlight.new
    @app.boot(launcher: @registry,
              zui: {
                launch: ->(app_id) { @calls << [:launch, app_id] },
                quit: ->(win_id) { @calls << [:quit, win_id] },
                focus: ->(win_id) { @calls << [:focus, win_id] },
                restore: ->(win_id) { @calls << [:restore, win_id] },
                collapse: ->(win_id) { @calls << [:collapse, win_id] },
              })
  end

  def test_filter_matches_title_and_id_case_insensitively
    assert_equal 3, @app.filtered_apps.size, '空查询 → 全部'

    @app.query = '文件'
    assert_equal ['文件管理器'], @app.filtered_apps.map { |a| a[:title] }

    @app.query = 'CLOCK'
    assert_equal [:clock], @app.filtered_apps.map { |a| a[:id] }, 'id 匹配、大小写不敏感'

    @app.query = '不存在的应用'
    assert_empty @app.filtered_apps
  end

  def test_state_and_labels
    assert_equal :idle, @app.app_state(:about)
    assert_equal '未运行', @app.state_label(:about)
    assert_equal '启动', @app.primary_label(:about)

    assert_equal :window, @app.app_state(:files)
    assert_equal '运行中', @app.state_label(:files)
    assert_equal '聚焦', @app.primary_label(:files)

    @running << FakeInst.new(:clock, :clock, :icon)
    assert_equal :icon, @app.app_state(:clock)
    assert_equal '已收起', @app.state_label(:clock)
    assert_equal '显示', @app.primary_label(:clock)
  end

  def test_activate_routes_by_state
    @app.activate(:about)
    assert_includes @calls, [:launch, :about], '未运行 → 经 shell 服务启动（开窗归 shell，R2）'

    @running << FakeInst.new(:clock, :clock, :icon)
    @app.activate(:clock)
    assert_includes @calls, [:restore, :clock], '收起形态 → 涨回窗口'

    @app.activate(:files)
    assert_includes @calls, [:focus, :files], '窗口形态 → 聚焦（相机飞行）'
  end

  def test_quit_disposes_every_instance_of_app
    @running << FakeInst.new(:files, :'files#2', :icon)
    @app.quit(:files)

    assert_equal [[:quit, :files], [:quit, :'files#2']], @calls, '多实例逐个真退出'
  end

  def test_cursor_wraps_around
    assert_equal 0, @app.cursor
    @app.move_cursor(-1)
    assert_equal 2, @app.cursor, '越界回绕（3 项，-1 → 末尾）'
    @app.move_cursor(1)
    assert_equal 0, @app.cursor
  end

  def test_activate_selected_uses_cursor
    @app.query = '时'
    @app.activate_selected
    assert_includes @calls, [:launch, :clock], '回车执行选中项'
  end

  def test_escape_collapses_spotlight_itself
    @app.handle_nav_key(Struct.new(:key).new('Escape'))
    assert_includes @calls, [:collapse, @app.win_id], 'Esc 收起启动器自身（不是别的窗）'
  end

  # 行内按钮必须先掐冒泡：否则 quit 后行的 on_click 会把实例重新启动
  #（浏览器实证：显示「退出没反应」）
  class FakeEvent
    attr_reader :stopped
    def stop_propagation = @stopped = true
  end

  def test_row_buttons_stop_propagation_before_acting
    @running << FakeInst.new(:clock, :clock, :icon)
    ev = FakeEvent.new
    @app.quit_from_button(ev, :clock)
    assert ev.stopped, '「退出」按钮先 stop_propagation'
    assert_equal [[:quit, :clock]], @calls, '再执行退出'

    ev2 = FakeEvent.new
    @app.primary_from_button(ev2, :clock)
    assert ev2.stopped, '主操作按钮先 stop_propagation'
    assert_equal [:restore, :clock], @calls.last, '再执行主操作'
  end

  def test_rev_bumps_after_actions
    before = @app.rev
    @app.activate(:about)
    assert_equal before + 1, @app.rev, '操作后 bump rev（列表状态刷新）'
  end
end
