#!/usr/bin/env ruby
# 把 PacketTunnel extension target 接入 ios/Runner.xcodeproj（幂等，可重复执行）。
# 本机无 macOS 时由 CI（macos runner）在 flutter build ios 前运行：
#   ruby script/ios-setup-packet-tunnel.rb
# 依赖 xcodeproj gem：gem install xcodeproj（CI 中已预装 macOS 系统 Ruby 可用）。
#
# 内容：
# 1. Runner target 加 Runner.entitlements + 编译 PacketTunnel/SharedState.swift（channel 桥共享态）
# 2. 新建 PacketTunnel app extension target（Info.plist/entitlements/4 个 Swift 源/hev xcframework）
# 3. Runner 依赖并 Embed 该 extension

require 'xcodeproj'

IOS_DIR = File.expand_path('../src/mobile/ios', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'Runner.xcodeproj')
EXT_NAME = 'PacketTunnel'
EXT_BUNDLE_ID = 'com.proxyscan.proxyConfigScan.PacketTunnel'
DEPLOYMENT_TARGET = '15.0'
EXT_SOURCES = %w[
  PacketTunnel/SharedState.swift
  PacketTunnel/Socks5Bridge.swift
  PacketTunnel/HevBridge.swift
  PacketTunnel/PacketTunnelProvider.swift
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' }
abort('未找到 Runner target') if runner.nil?

def configure_extension_settings(target)
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
    settings['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
    settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
    settings['SWIFT_VERSION'] = '5.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  end
end

# ---- 1. Runner：entitlements + SharedState.swift ----

unless runner.build_configurations.any? { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] == 'Runner/Runner.entitlements' }
  runner.build_configurations.each do |config|
    config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  end
  puts 'Runner: 已挂 Runner.entitlements'
end

runner_group = project.main_group['Runner'] || project.main_group.new_group('Runner', 'Runner')
unless runner.source_build_phase.files_references.any? { |f| f.path.to_s.end_with?('SharedState.swift') }
  ref = runner_group.new_file('../PacketTunnel/SharedState.swift')
  runner.add_file_references([ref])
  puts 'Runner: 已加入 PacketTunnel/SharedState.swift'
end
unless runner.source_build_phase.files_references.any? { |f| f.path.to_s.end_with?('VpnChannelHandler.swift') }
  ref = runner_group.new_file('VpnChannelHandler.swift')
  runner.add_file_references([ref])
  puts 'Runner: 已加入 Runner/VpnChannelHandler.swift'
end
unless runner.source_build_phase.files_references.any? { |f| f.path.to_s.end_with?('SystemChannelHandler.swift') }
  ref = runner_group.new_file('SystemChannelHandler.swift')
  runner.add_file_references([ref])
  puts 'Runner: 已加入 Runner/SystemChannelHandler.swift'
end

# ---- 2. PacketTunnel extension target ----

ext = project.targets.find { |t| t.name == EXT_NAME }
if ext.nil?
  ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET)
  configure_extension_settings(ext)

  ext_group = project.main_group.new_group(EXT_NAME, EXT_NAME)
  info_ref = ext_group.new_file('Info.plist')
  ent_ref = ext_group.new_file("#{EXT_NAME}.entitlements")
  info_ref.last_known_file_type = 'text.plist.xml'
  ent_ref.last_known_file_type = 'text.plist'

  EXT_SOURCES.each do |path|
    ref = ext_group.new_file(File.basename(path))
    ref.last_known_file_type = 'sourcecode.swift'
    ext.add_file_references([ref])
  end

  hev_path = File.join(IOS_DIR, 'Frameworks', 'HevSocks5Tunnel.xcframework')
  if File.directory?(hev_path)
    fw_group = project.main_group.new_group('Frameworks', 'Frameworks')
    fw_ref = fw_group.new_file('HevSocks5Tunnel.xcframework')
    fw_ref.last_known_file_type = 'wrapper.xcframework'
    ext.frameworks_build_phase.add_file_reference(fw_ref)
    puts 'PacketTunnel: 已链接 HevSocks5Tunnel.xcframework'
  else
    puts '警告: 未找到 ios/Frameworks/HevSocks5Tunnel.xcframework（hev 未构建？extension 链接将失败）'
  end
  puts "PacketTunnel: 已创建 extension target（#{EXT_BUNDLE_ID}）"
else
  puts 'PacketTunnel: target 已存在，跳过创建'
end

# FLUTTER_BUILD_NAME/NUMBER 经 Runner 的 xcconfig 链传入；extension target 不挂相同 base config
# 时版本变量展开为空，产物 Info.plist 缺 CFBundleVersion，真机安装被 installd 拒（MissingBundleVersion）
runner.build_configurations.each do |rc|
  ec = ext.build_configurations.find { |c| c.name == rc.name }
  next if ec.nil? || ec.base_configuration_reference == rc.base_configuration_reference
  ec.base_configuration_reference = rc.base_configuration_reference
  puts "PacketTunnel: #{ec.name} 已挂 base config（对齐 Runner）"
end

# ---- 3. Runner 依赖 + Embed App Extensions ----

unless runner.dependencies.any? { |d| d.target == ext }
  runner.add_dependency(ext)
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  embed.add_file_reference(ext.product_reference)
  # flutter#135056：Embed 必须在 Run Script/Thin Binary 之前，否则新构建系统报依赖循环
  first_script_idx = runner.build_phases.index { |ph| ph.isa == 'PBXShellScriptBuildPhase' } || runner.build_phases.size
  runner.build_phases.delete(embed)
  runner.build_phases.insert(first_script_idx, embed)
  puts 'Runner: 已依赖并 Embed PacketTunnel extension（置于 Run Script 之前）'
end

project.save
puts 'project.pbxproj 已更新'
