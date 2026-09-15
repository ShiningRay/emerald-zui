# emerald-zui

[![CI](https://github.com/ShiningRay/emerald-zui/actions/workflows/ci.yml/badge.svg)](https://github.com/ShiningRay/emerald-zui/actions/workflows/ci.yml)

Emerald OS 的 ZUI（Zoomable User Interface）视口扩展：无限画布桌面——
相机缩放即导航、平移即浏览，经典桌面是其退化形态。

- 开发计划与决策事实源：[docs/PLAN.md](docs/PLAN.md)
- 依赖（兄弟目录 path）：[citrine](../citrine) 内核 / [beryl](../beryl) 组件库 / [emerald](../emerald) 系统层

```bash
export PATH="$HOME/.rbenv/shims:$PATH"   # 系统 ruby 2.6 无 bundler 2.7.2（emerald 工具链备忘同款）
bundle install
bundle exec rake                          # CRuby 单测 + Opal 编译验收

# 开发（热刷新）
cd ../citrine && bin/citrine dev ../emerald-zui/examples -I ../beryl/lib -I ../emerald/lib -I ../emerald-zui/lib
```
