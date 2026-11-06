import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/proxy_uri_validator.dart';
import 'history_state.dart';
import 'last_scan_state.dart';

/// 扫码结果状态。
sealed class ScanState {
  const ScanState();
}

class ScanIdle extends ScanState {
  const ScanIdle();
}

class ScanSuccess extends ScanState {
  const ScanSuccess(this.config, {this.wanWarning = false, this.loopbackWarning = false});

  final ProxyConfig config;

  /// host 非公网保留段，UI 需提示"目标似乎不在局域网"
  final bool wanWarning;

  /// host 为回环（127.0.0.1/localhost），代理不在手机上，启动必失败
  final bool loopbackWarning;
}

class ScanFailure extends ScanState {
  const ScanFailure(this.message);

  final String message;
}

class ScanNotifier extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanIdle();

  /// 解析成功先同步置位（首个 await 前），再并行落历史与最近扫码。
  /// 落库失败原样上抛，由扫码页提示，不改写已成功的解析结果。
  Future<void> onBarcode(String raw) async {
    final ProxyConfig config;
    try {
      config = ProxyUriValidator.parse(raw);
    } on ProxyParseException catch (e) {
      state = ScanFailure(e.message);
      return;
    }
    state = ScanSuccess(
      config,
      wanWarning: !config.isLanHost && !config.isLoopbackHost,
      loopbackWarning: config.isLoopbackHost,
    );
    // 解析成功即落历史（同 host:port 仅刷新 last_used_at）
    await Future.wait([
      ref.read(historyProvider.notifier).recordScan(config),
      ref.read(lastScanProvider.notifier).record(config),
    ]);
  }

  void clear() => state = const ScanIdle();
}

final scanProvider = NotifierProvider<ScanNotifier, ScanState>(ScanNotifier.new);
