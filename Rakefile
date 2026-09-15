# frozen_string_literal: true

require 'rake/testtask'

CITRINE = ENV.fetch('CITRINE_PATH', '../citrine')
BERYL   = ENV.fetch('BERYL_PATH', '../beryl')
EMERALD = ENV.fetch('EMERALD_PATH', '../emerald')

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << File.join(CITRINE, 'lib') << File.join(BERYL, 'lib') << File.join(EMERALD, 'lib')
  t.test_files = FileList['test/**/*_test.rb']
end

desc 'Opal 编译验收：ZUI 整机示例可编译（浏览器侧语法门）'
task :compile do
  sh "bundle exec opal -c -I. -I#{File.join(CITRINE, 'lib')} -I#{File.join(BERYL, 'lib')} -I#{File.join(EMERALD, 'lib')} -Ilib -o examples/zui_desktop.js examples/zui_desktop.rb"
end

task default: %i[test compile]
