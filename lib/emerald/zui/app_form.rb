# frozen_string_literal: true

module Emerald
  module Zui
    # 形态态机支持（docs/PLAN.md §3.8）：include 进 Emerald::App——
    # 窗口即图标，同一实例两种形态（B 方案，D6）。
    #
    # ⚠️ 契约桩（并行开发基准，完整实现会补充：生命周期守卫、级联几何、
    # dispose 清理、include 挂载）：实例级 form / icon_geometry /
    # window_geometry_backup 惰性默认 + icon_view 默认渲染（glyph + 标题徽标）。
    # 图标形态渲染在 shell 的 view 上下文里调用 inst.icon_view——App 是
    # Citrine::Component 子类，DSL 在实例上可用，节点 owner 归实例（插槽模式）。
    module AppForm
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

      # 图标形态默认视图：glyph + 标题（无声明应用的兼容降级，D7）
      def icon_view
        box(css_class: 'zui-iconform-default') do
          box(css_class: 'zui-iconform-glyph') { self.class.app_icon.to_s }
          box(css_class: 'zui-iconform-name') { self.class.app_title.to_s }
        end
      end
    end
  end
end
