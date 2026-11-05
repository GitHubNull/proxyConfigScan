import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/proxy_uri_validator.dart';
import 'history_state.dart';

/// 扫码结果状态。
sealed class ScanState {
  const ScanState();
}

class ScanIdle extends ScanState {
  const ScanIdle();
}

class ScanSuccess extends ScanState {
  const ScanSuccess(this.config, {this.wanWarning = false});

  final ProxyConfig config;

  /// host 非公网保留段，UI 需提示"目标似乎不在局域网"
  final bool wanWarning;
}

class ScanFailure extends ScanState {
  const ScanFailure(this.message);

  final String message;
}

class ScanNotifier extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanIdle();

  void onBarcode(String raw) {
    try {
      final config = ProxyUriValidator.parse(raw);
      state = ScanSuccess(config, wanWarning: !config.isLanHost);
      // 解析成功即落历史（同 host:port 仅刷新 last_used_at）
      ref.read(historyProvider.notifier).recordScan(config);
    } on ProxyParseException catch (e) {
      state = ScanFailure(e.message);
    }
  }

  void clear() => state = const ScanIdle();
}

final scanProvider = NotifierProvider<ScanNotifier, ScanState>(ScanNotifier.new);
