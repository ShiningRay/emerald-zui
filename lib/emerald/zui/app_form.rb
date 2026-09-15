# frozen_string_literal: true

module Emerald
  module Zui
    # 形态态机支持（docs/PLAN.md §3.8）：include 进 Emerald::App——
    # 窗口即图标，同一实例两种形态（B 方案，D6）。
    #
    # 本模块只管实例侧的纯状态：form / 两套几何的簿记 + 切换守卫，零副作用
    # 纯 CRuby 可测（beryl F5）。wm.close/open、世界层幽灵形变、图标 tile
    # 渲染/拖移全归 ZuiShell——wm 由 shell 持有（D2），App 不反向索求。
    # 图标形态渲染：shell 在 view 上下文里调 inst.icon_view（App 是
    # Citrine::Component 子类，DSL 实例级可用，节点 owner 归实例，插槽模式）。
    module AppForm
      # 合法形态集（PLAN §3.8：窗口 ⇄ 图标两种表达态）
      VALID_FORMS = %i[window icon].freeze
      # 首次缩起的驻留级联步长（icon_slot 纯函数用）：同位叠加逐次错开
      ICON_SLOT_OFFSET = 24

      def form
        @form ||= :window
      end

      attr_writer :form

      def icon_geometry
        @icon_geometry
      end

      attr_writer :icon_geometry

      def window_geometry_backup
        @window_geometry_backup
      end

      attr_writer :window_geometry_backup

      # 形态切换状态机（纯状态段；经 shell 的事件回调进入，F6 安全区）：
      #   morph_to(:icon, window_geometry: g)  window→icon：暂存窗口几何
      #     （供还原），flip form；返回 nil
      #   morph_to(:window)  icon→window：flip form，取出并消费 backup
      #     （一次性——backup 语义是「缩起时暂存」），返回恢复几何；nil 表示
      #     无备份，调用方走级联兜底（PLAN §3.8「几何取 backup 或级联」）
      # 守卫：非法形态 raise；同形态 no-op（幂等，重复触发安全——双击双派
      # 发的去重另有 shell 侧时间窗守卫，这里是状态机自身的第二道）。
      def morph_to(target, window_geometry: nil)
        target = target.to_sym
        unless VALID_FORMS.include?(target)
          raise ArgumentError, "非法形态 #{target.inspect}（合法形态：#{VALID_FORMS.join(' / ')}）"
        end

        case target
        when :icon
          return nil if form == :icon

          @window_geometry_backup = window_geometry
          @form = :icon
          nil
        when :window
          return nil if form == :window

          @form = :window
          @window_geometry_backup.tap { @window_geometry_backup = nil }
        end
      end

      # 图标驻留几何的级联缺省（纯函数）：以缩起时的窗口位置为基点，按当时
      # 已驻留图标数 seq 逐级错开——同位叠死的多个窗口各得其所。分配与写回
      # 归 shell（ensure_icon_geometry）：icon_geometry 一经驻留不覆盖，
      # 用户拖过位就永驻该位，下次缩起落回此处（PLAN §3.8「可拖拽驻留」）
      def self.icon_slot(base_geometry, seq)
        { x: base_geometry[:x] + seq * ICON_SLOT_OFFSET,
          y: base_geometry[:y] + seq * ICON_SLOT_OFFSET }
      end

      # 图标形态默认视图：与桌面启动器图标**完全同款**——复用 .d-icon-glyph /
      # .d-icon-name 的页面 CSS（不另造样式、不内联外观），窗口缩回后看到的
      # 就是那颗图标，而不是一个「迷你窗口」样的深色卡片（用户验收反馈：
      # tile 曾带不透明底 + 边框 + 投影）。覆写即活图标：icon_view 内读实例
      # signal → 样式/徽标，天然实时（垃圾桶空满、邮箱未读、时钟指针同机制）
      def icon_view
        box(css_class: 'zui-iconform-default') do
          box(css_class: 'd-icon-glyph') { self.class.app_icon.to_s }
          label(css_class: 'd-icon-name') { self.class.app_title.to_s }
        end
      end
    end
  end
end
