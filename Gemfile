# frozen_string_literal: true

source 'https://rubygems.org'

# 与 emerald 同纪律：path 依赖本地/CI 兄弟目录；emerald 无 gemspec（应用仓），
# 不进 Gemfile，走 Rakefile/编译命令的 -I 与 EMERALD_PATH 环境变量
gem 'citrine', path: ENV.fetch('CITRINE_PATH', '../citrine')
gem 'citrine-beryl', path: ENV.fetch('BERYL_PATH', '../beryl'), require: 'beryl'

# Opal 编译验收（rake compile）本地与 CI 都要用
gem 'opal', '~> 1.8', require: false

gem 'minitest', '~> 5.0'
gem 'rake', '~> 13.0'
