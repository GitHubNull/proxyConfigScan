import 'package:flutter/material.dart';

import '../util/proxy_uri_validator.dart';

/// 启动代理上游前的统一校验（历史页复用与状态页回填共用）。
///
/// 返回 true 表示可以继续启动。顺序必须先回环后局域网判断：
/// [ProxyUriValidator.isLanHost] 把 127/8 也算私网段。
Future<bool> ensureUpstreamReady(
  BuildContext context,
  ProxyConfig config,
) async {
  if (config.isLoopbackHost) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('地址不可用'),
        content: Text(
          '${config.host} 是回环地址（手机本机），Burp 代理并不在手机上，启动后必然连不上。\n\n'
          '请在 Burp 代理监听器绑定电脑局域网 IP（或全部接口）后重新扫码。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return false;
  }
  if (!config.isLanHost) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('目标不在局域网'),
        content: Text('${config.upstream} 似乎不是局域网地址，手机可能无法连通。仍要启动吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍要启动'),
          ),
        ],
      ),
    );
    return proceed == true;
  }
  return true;
}
