# backtick_javascript: true
# frozen_string_literal: true

module Emerald
  module Zui
    # 形变引擎（docs/PLAN.md §3.9）：形态切换的执行层——世界层内 FLIP 幽灵，
    # 只动画 transform（中心差 translate + 非均匀 scale，即「变形」观感）
    # + border-radius + 内容交叉淡化，DURATION_MS 收束。两端同在世界
    # transform 容器内，相机无关零换算。
    #
    # 纯数学段 transform(from, to) CRuby 可测（CSS transform 串生成）；
    # 执行段 fly(world_el, panel_el, from_rect, to_rect, on_done)：Opal 下把
    # panel_el 深克隆成幽灵（剥 id、absolute 定位于源形态世界矩形、
    # transitionend + 兜底定时器双保险收场、摘幽灵后回 on_done 渲染目标
    # 形态），CRuby/SSR 直接 on_done。防重入 @morphing（§3.9）经
    # Morph.morphing? 暴露——外壳动画期跳过两端 form 渲染，只有幽灵。
    module Morph
      DURATION_MS = 320
      # 收束端减速的 ease-out 系缓动：轮廓「落定」感
      EASING = 'cubic-bezier(0.3, 0.7, 0.4, 1)'
      # 兜底定时器缓冲：transitionend 丢失（后台标签页等）时收场用，
      # 略长于动画时长即可
      FALLBACK_BUFFER_MS = 80

      class << self
        # ── 纯数学段：世界矩形 → CSS transform 串 ──────────

        # from/to 为 {x, y, w, h} 世界矩形（to 可额外带 :radius，见 fly）。
        # transform-origin 居中语义：translate = 两矩形中心差，scale =
        # 目标/源 宽高比（非均匀，即变形）。幽灵几何定位于源矩形，恒等变换
        # 即源形态，本串是它到目标形态的一次变换。
        def transform(from, to)
          check_rect!(from, '源')
          check_rect!(to, '目标')

          dx = center(to)[0] - center(from)[0]
          dy = center(to)[1] - center(from)[1]
          sx = to[:w].to_f / from[:w]
          sy = to[:h].to_f / from[:h]
          "translate(#{px(dx)}, #{px(dy)}) scale(#{num(sx)}, #{num(sy)})"
        end

        # ── 执行段：克隆幽灵飞一次 ─────────────────────────

        # world_el：世界层 DOM（幽灵的 absolute 包含块，即相机 transform 容器）
        # panel_el：源形态真实面板（仅作克隆素材，同步克隆——调用方可随即
        #           切 form 卸载源形态，脱离文档的节点照常 cloneNode）
        # from_rect/to_rect：两端世界矩形；to_rect 可带 :radius（图标形态
        #           圆角与窗口 10px 不同时传入，border-radius 随之形变）
        # on_done：收场回调（外壳渲染目标形态、清自己的防重入标志）
        def fly(world_el, panel_el, from_rect, to_rect, on_done)
          return on_done.call unless defined?(Opal)
          # 防重入（§3.9）：动画在飞时第二发切换不起第二只幽灵，立即完成
          # 态切换兜底——世界状态不被动画绑架（此间 Morph.morphing? 仍 true）
          return on_done.call if morphing?

          @morphing = true
          ghost = panel_el.cloneNode(true)
          strip_clone_ids(ghost)
          strip_hook_classes(ghost)
          ghost[:className] = "#{ghost[:className]} zui-morph-ghost"
          gs = ghost[:style]
          # 初始几何 = 源形态世界矩形（内联；CSS 类只管静态语义，见示例页）
          gs[:left] = px(from_rect[:x])
          gs[:top] = px(from_rect[:y])
          gs[:width] = px(from_rect[:w])
          gs[:height] = px(from_rect[:h])
          gs[:transition] = "transform #{DURATION_MS}ms #{EASING}, border-radius #{DURATION_MS}ms #{EASING}"
          # 内容淡出动画的时长单一事实源在 Ruby：CSS 段 var() 消费，缺省 320ms
          gs.setProperty('--morph-ms', "#{DURATION_MS}ms")
          world_el.appendChild(ghost)

          settled = false
          timer = nil
          settle = -> {
            return if settled
            settled = true
            @morphing = false
            Beryl::Timer.cancel(timer)
            ghost.remove
            on_done.call
          }
          # 双保险收场：transitionend（滤 transform；border-radius 同刻到达）
          # 为主，兜底定时器兜「后台标签页 transitionend 不派发」
          ghost.addEventListener('transitionend', ->(raw) {
            ev = Native(raw)
            settle.call if ev[:propertyName] == 'transform'
          })
          timer = Beryl::Timer.after(DURATION_MS + FALLBACK_BUFFER_MS) { settle.call }

          ghost[:offsetWidth] # 强制 reflow：transition 在场后再写目标值才动画
          gs[:transform] = transform(from_rect, to_rect)
          gs[:borderRadius] = to_rect[:radius].to_s if to_rect[:radius]
          nil
        end

        # 防重入标志（§3.9 @morphing）：动画期外壳据此跳过两端 form 渲染
        def morphing?
          !!@morphing
        end

        private

        def center(rect)
          [rect[:x].to_f + rect[:w].to_f / 2, rect[:y].to_f + rect[:h].to_f / 2]
        end

        # 矩形契约：四键齐全（缺键报错文案对齐 camera.rb）+ 尺寸为正
        # （源尺寸为 0 会让 scale 除零出 Infinity）
        def check_rect!(rect, label)
          missing = %i[x y w h] - rect.keys
          raise ArgumentError, "#{label}矩形缺少键：#{missing.join('、')}" unless missing.empty?
          return if rect[:w].to_f.positive? && rect[:h].to_f.positive?

          raise ArgumentError, "#{label}矩形尺寸必须为正：w=#{rect[:w]} h=#{rect[:h]}"
        end

        # 数值去尾随零：110.0 → 110（CSS 串干净，单测可钉等值）
        def num(n, digits = 4)
          v = n.round(digits)
          v == v.to_i ? v.to_i : v
        end

        def px(n)
          "#{num(n, 2)}px"
        end

        # 幽灵不是真面板：剥掉窗口挂钩类（zui-win-* 等 zui- 前缀行为类）——
        # 否则按类查询的地方（小地图缩略图同步）会把幽灵当成真面板克隆并
        # 改写它的内联定位/transform，飞行动画中途被打断（浏览器实证：
        # 幽灵被写成缩略图比例 scale(0.1139)、left/top 归 0）
        def strip_hook_classes(clone)
          %x{
            var el = #{clone.to_n};
            el.className = el.className.replace(/\bzui-(win|iconform)-\S+/g, '').trim();
          }
          nil
        end

        # 克隆体剥掉全部 id：与真实面板同 id 进文档会串（getElementById/
        # label for；小地图缩略图同款，minimap.rb strip_clone_ids）
        def strip_clone_ids(clone)
          %x{
            var root = #{clone.to_n};
            root.removeAttribute('id');
            var els = root.querySelectorAll('[id]');
            for (var i = 0; i < els.length; i++) { els[i].removeAttribute('id'); }
          }
          nil
        end
      end
    end
  end
end
