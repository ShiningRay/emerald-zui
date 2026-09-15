# frozen_string_literal: true

module Emerald
  module Zui
    module Apps
      # 启动器（Spotlight 式，§3.8 修订③）：桌面不再放应用启动器图标，启动
      # 入口统一收敛到这里——⌘K 呼出，输入即过滤，点行/回车执行主操作：
      #   未运行 → 启动；窗口形态 → 聚焦（相机飞行到位）；收起形态 → 涨回窗口
      # 行尾「退出」按钮 → 真退出该实例（quit_app）。
      #
      # 能力面（D10）：只经 ctx 取服务——registry 走 ctx[:launcher]，ZUI 专有
      # 操作（退出/聚焦/涨回）走 ctx[:zui]（shell 注入的 lambda，保持应用对
      # shell 零知识）。实例增删/形态变化无信号可订阅，故每次操作后自增
      # rev 触发本窗重渲染（列表状态：未运行/运行中/已收起随之刷新）。
      class Spotlight < Emerald::App
        app_id    :spotlight
        app_title '启动器'
        app_icon  '⌘'
        singleton true
        default_geometry { { x: 380, y: 200, w: 460, h: 400 } }

        state(:query) { '' }   # 搜索词（text_input 双向绑定）
        state(:cursor) { 0 }   # 当前选中项在过滤结果里的下标
        state(:rev) { 0 }      # 外部状态（实例增删/形态）变更后的重渲染信号

        # 注意（浏览器实证踩坑）：**所有信号读取必须发生在各自的块内**——
        # 列表依赖（query/rev）若在块外求值，订阅会落在视图根块上，每次
        # 输入都整树重建、输入框被摘了再挂回（焦点丢失、只能输一个字符）。
        # 故 rev/query 一律在 result_list 的块内读。
        def view
          stack(gap: 8, style: { padding: '12px', width: '100%', height: '100%' }) do
            search_box
            result_list
            footer_hint
          end
        end

        # ── 纯逻辑段（CRuby 单测直钉）────────────────────────

        # 过滤：空查询 = 全部；否则 title / id 大小写不敏感包含匹配
        def filtered_apps
          all = launcher ? launcher.apps : []
          q = query.to_s.strip.downcase
          return all if q.empty?

          all.select do |app|
            app[:title].to_s.downcase.include?(q) || app[:id].to_s.downcase.include?(q)
          end
        end

        # 该应用当前状态：:idle（无实例）/ :window（有窗口形态）/:icon（收起）
        def app_state(app_id)
          inst = instances_of(app_id).last
          return :idle unless inst

          inst.form == :icon ? :icon : :window
        end

        STATE_LABEL = { idle: '未运行', window: '运行中', icon: '已收起' }.freeze
        STATE_ACTION = { idle: '启动', window: '聚焦', icon: '显示' }.freeze

        def state_label(app_id)
          STATE_LABEL[app_state(app_id)]
        end

        def primary_label(app_id)
          STATE_ACTION[app_state(app_id)]
        end

        # 主操作路由（点行 / 回车）：未运行启动；收起涨回；窗口聚焦
        def activate(app_id)
          inst = instances_of(app_id).last
          case app_state(app_id)
          when :idle
            # 经 shell 的 launch 服务开窗（registry.launch 只建实例，R2）
            zui_op(:launch, app_id)
          when :icon
            zui_op(:restore, inst.win_id)
          else
            zui_op(:focus, inst.win_id)
          end
          bump_rev
        end

        # 行尾「退出」：该应用所有实例真退出（多实例逐个回收）
        def quit(app_id)
          instances_of(app_id).each { |inst| zui_op(:quit, inst.win_id) }
          bump_rev
        end

        def instances_of(app_id)
          return [] unless launcher

          launcher.each_running.select { |inst| inst.class.app_id == app_id.to_sym }
        end

        # ── 渲染段 ──────────────────────────────────────────

        def search_box
          text_input(value: signal(:query), placeholder: '搜索应用…（回车执行，Esc 关闭）',
                     on_enter: -> { activate_selected },
                     on_key: ->(ev) { handle_nav_key(ev) },
                     css_class: 'b-search-input',
                     # 高度固定：外层是 column flex，不锁高会被拉满整窗
                     style: { height: '34px', flex: '0 0 auto' })
        end

        def result_list
          stack(css_class: 'b-list', gap: 2, style: { flex: '1', overflow: 'auto' }) do
            rev # 读即订阅（块内）：操作后刷新状态标签
            rows = filtered_apps # 读即订阅（块内）：query 变化只重建列表
            if rows.empty?
              label(css_class: 'b-empty') { '没有匹配的应用' }
            else
              rows.each_with_index { |app, i| result_row(app, i) }
            end
          end
        end

        def result_row(app, index)
          # key 必须给：行内「退出」按钮是条件渲染的（有实例才出现），
          # 无 key 时 citrine 的按位复用会把节点对错位、监听器留在旧节点上
          # ——按钮点了没反应（浏览器实证踩坑）
          row(css_class: row_class(index), key: "row:#{app[:id]}", gap: 8,
              style: { align_items: 'center', padding: '6px 8px' },
              on_click: ->(_e) { activate(app[:id]) }) do
            box(css_class: 'd-icon-glyph', style: { font_size: '18px' }) { app[:icon].to_s }
            label(style: { flex: '1' }) { app[:title].to_s }
            label(css_class: 'b-badge') { state_label(app[:id]) }
            # 行内按钮必须 stop_propagation：否则 click 冒泡到整行的 on_click
            # ——先 quit 关掉实例，行处理器紧接着按「已变回未运行」把它重新
            # 启动（浏览器实证：看着像「退出没反应」）
            button(key: "primary:#{app[:id]}",
                   on_click: ->(e) { primary_from_button(e, app[:id]) }) { primary_label(app[:id]) }
            if app_state(app[:id]) != :idle
              button(key: "quit:#{app[:id]}",
                     on_click: ->(e) { quit_from_button(e, app[:id]) }) { '退出' }
            end
          end
        end

        def row_class(index)
          index == cursor ? 'b-list-row is-selected' : 'b-list-row'
        end

        def footer_hint
          label(css_class: 'b-statusbar') { '↑↓ 选择 · 回车执行 · 行尾「退出」结束应用' }
        end

        # ── 键盘导航 ────────────────────────────────────────

        def handle_nav_key(ev)
          case ev.key
          when 'ArrowDown' then move_cursor(1)
          when 'ArrowUp' then move_cursor(-1)
          when 'Escape' then zui_op(:collapse, win_id) # Esc = 收起启动器自己
          end
        end

        def move_cursor(delta)
          size = filtered_apps.size
          return if size.zero?

          # 循环滚动（越界回绕，导航不卡死）
          self.cursor = (cursor + delta) % size
        end

        # 行内按钮入口（可测：断言先 stop_propagation 再执行，防冒泡回归）
        def primary_from_button(ev, app_id)
          ev.stop_propagation
          activate(app_id)
        end

        def quit_from_button(ev, app_id)
          ev.stop_propagation
          quit(app_id)
        end

        def activate_selected
          app = filtered_apps[cursor]
          activate(app[:id]) if app
        end

        private

        def launcher
          ctx && (ctx[:launcher] || ctx['launcher'])
        end

        def zui_op(op, *args)
          services = ctx && (ctx[:zui] || ctx['zui'])
          services && services[op]&.call(*args)
        end

        def bump_rev
          self.rev = rev + 1
        end
      end
    end
  end
end
