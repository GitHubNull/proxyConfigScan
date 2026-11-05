import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../state/scan_state.dart';
import '../../state/vpn_state.dart';
import '../../util/proxy_uri_validator.dart';
import '../../vpn/proxy_engine.dart';

/// 扫码页：相机预览 + 扫码解析结果展示。
/// 解析与校验在 [scanProvider]（ProxyUriValidator，规范见 doc/qr-format-spec.md）。
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  // 注意：不要给 controller 传 detectionTimeoutMs 等可选参数，
  // mobile_scanner 6.x 在 Android 上因此 NPE（见 M1 真机验证记录）
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    _handled = true;
    ref.read(scanProvider.notifier).onBarcode(raw);
  }

  void _resume() {
    _handled = false;
    ref.read(scanProvider.notifier).clear();
    _controller.start();
  }

  Future<void> _startVpn(ProxyConfig config) async {
    try {
      await ref.read(vpnControllerProvider).start(config);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('代理转发已启动：${config.upstream}')),
        );
      }
    } on VpnEngineException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(vpnErrorText(e.code, e.message))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanProvider);

    return Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: scan is ScanIdle ? _onDetect : null,
        ),
        if (scan is ScanIdle)
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '对准 Burp 代理配置二维码',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ),
          )
        else
          _ResultOverlay(
            scan: scan,
            onResume: _resume,
            onStart: scan is ScanSuccess ? () => _startVpn(scan.config) : null,
          ),
      ],
    );
  }
}

class _ResultOverlay extends StatelessWidget {
  const _ResultOverlay({
    required this.scan,
    required this.onResume,
    this.onStart,
  });

  final ScanState scan;
  final VoidCallback onResume;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final (icon, title, detail, color) = switch (scan) {
      ScanSuccess(:final config, :final wanWarning) => (
          Icons.check_circle,
          '解析成功',
          wanWarning
              ? '代理地址：${config.upstream}\n\n提示：目标似乎不在局域网，请确认 Burp 代理地址正确。'
              : '代理地址：${config.upstream}',
          Colors.green,
        ),
      ScanFailure(:final message) => (Icons.error, '无法识别', message, Colors.red),
      _ => (Icons.info, '等待扫码', '', Colors.grey),
    };

    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 64),
          const SizedBox(height: 16),
          Text(title, style: TextStyle(color: color, fontSize: 22)),
          const SizedBox(height: 12),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 24),
          if (onStart != null) ...[
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.vpn_lock),
              label: const Text('启动代理'),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: onResume,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('继续扫码'),
          ),
        ],
      ),
    );
  }
}
