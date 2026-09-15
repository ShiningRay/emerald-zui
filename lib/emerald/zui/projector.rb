# frozen_string_literal: true

module Emerald
  module Zui
    # 小地图投影器（PLAN §8 防迷路三件套之一）：世界包围盒 ↔ HUD 小地图像素框
    # 的线性映射，外加窗口矩形并集工具。纯 CRuby 可测，零 Opal 依赖——小地图
    # 组件拿它把窗口/相机取景框画进像素框，点击/拖拽落点经 to_world 逆映射回
    # 世界坐标后交给 Camera#center_on。
    #
    # 映射契约（单测锁定，勿改）：
    #   s = min((box.w − 2p)/bounds.w, (box.h − 2p)/bounds.h)   # p = padding
    #   短轴居中留白：映射后的包围盒在 box 内两轴皆居中
    #   to_map(wx, wy)   = [(wx − bx)·s + ox, (wy − by)·s + oy]
    #   to_world(mx, my) 为其逆映射
    # bounds.w/h ≤ 0 的退化情形按 1 算（空世界/单点世界不翻转、不除零）。
    class Projector
      # 小地图内边距默认 8px
      DEFAULT_PADDING = 8

      # bounds = 世界包围盒 {x:, y:, w:, h:}；box = 小地图像素尺寸 {w:, h:}；
      # padding = 内边距 px。值对象语义：映射参数初始化时固定，之后只读。
      def initialize(bounds:, box:, padding: DEFAULT_PADDING)
        @bounds_x = Float(bounds[:x])
        @bounds_y = Float(bounds[:y])
        @bounds_w = positive_or_one(bounds[:w])
        @bounds_h = positive_or_one(bounds[:h])
        @box_w = Float(box[:w])
        @box_h = Float(box[:h])
        @padding = Float(padding)

        @scale = [(@box_w - 2.0 * @padding) / @bounds_w,
                  (@box_h - 2.0 * @padding) / @bounds_h].min
        @origin_x = (@box_w - @bounds_w * @scale) / 2.0
        @origin_y = (@box_h - @bounds_h * @scale) / 2.0
      end

      # 世界 → 小地图像素的等比缩放系数
      attr_reader :scale

      # 世界坐标 → 小地图像素坐标（相对小地图盒左上角；线性：减 bounds 原点、
      # 乘 scale、加居中偏移）
      def to_map(wx, wy)
        [(Float(wx) - @bounds_x) * @scale + @origin_x,
         (Float(wy) - @bounds_y) * @scale + @origin_y]
      end

      # 小地图像素坐标 → 世界坐标（to_map 的逆映射；点击/拖拽导航用）
      def to_world(mx, my)
        [(Float(mx) - @origin_x) / @scale + @bounds_x,
         (Float(my) - @origin_y) / @scale + @bounds_y]
      end

      # 窗口矩形数组 [{x:, y:, w:, h:}] 的并集包围盒；空数组 → 零矩形
      # （供「世界包围盒 = 全部窗口 union」；调用方对零矩形决定兜底策略）
      def self.union(rects)
        return { x: 0, y: 0, w: 0, h: 0 } if rects.empty?

        xs = rects.map { |r| Float(r[:x]) }
        ys = rects.map { |r| Float(r[:y]) }
        rights = rects.map { |r| Float(r[:x]) + Float(r[:w]) }
        bottoms = rects.map { |r| Float(r[:y]) + Float(r[:h]) }
        { x: xs.min, y: ys.min, w: rights.max - xs.min, h: bottoms.max - ys.min }
      end

      private

      # 退化维度按 1 算：空世界（union 出的零矩形）/单点世界因此缩放到
      # 可用尺寸，而不是被 0 除出 Infinity 或负缩放翻转坐标轴
      def positive_or_one(v)
        f = Float(v)
        f > 0.0 ? f : 1.0
      end
    end
  end
end
