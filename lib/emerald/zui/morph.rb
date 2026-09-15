# frozen_string_literal: true

module Emerald
  module Zui
    # 形变引擎（docs/PLAN.md §3.9）：世界层内 FLIP 幽灵——只动画 transform
    # （中心差 translate + 非均匀 scale + border-radius + 内容交叉淡化）。
    #
    # ⚠️ 契约桩（并行开发基准，完整实现替换本文件）：
    #   - Morph.transform(from, to) → CSS transform 串（transform-origin 居中
    #     语义：translate = 两矩形中心差，scale = 目标/源 宽高比）
    #   - Morph.fly(world_el, panel_el, from_rect, to_rect, on_done)
    #     Opal 下克隆执行动画后回调；CRuby 直接 on_done（测试友好兜底）
    #   - Morph::DURATION_MS = 320
    module Morph
      DURATION_MS = 320

      def self.transform(_from, _to)
        raise NotImplementedError, 'Morph.transform 契约桩：待完整实现替换'
      end

      def self.fly(_world_el, _panel_el, _from_rect, _to_rect, on_done)
        on_done.call
      end
    end
  end
end
