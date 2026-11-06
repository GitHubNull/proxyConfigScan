import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../state/app_state.dart';
import '../../state/scan_state.dart';
import '../../state/vpn_state.dart';
import '../../system/system_channel.dart';
import '../../util/camera_policy.dart';
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
  final MobileScannerController _controller =
      MobileScannerController(autoStart: false);
  late final AppLifecycleListener _lifecycle;
  bool _resumed = true;
  bool _applying = false;
  bool _syncScheduled = false;
  bool _retryRequested = false;

  @override
  void initState() {
    super.initState();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _resumed =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final resumed = state == AppLifecycleState.resumed;
        if (resumed == _resumed) return;
        _resumed = resumed;
        _scheduleSync();
      },
    );
    // 首帧后 MobileScanner 已 attach controller，再启动相机
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleSync());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleSync() {
    if (!mounted || _syncScheduled) return;
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (mounted) unawaited(_applyDesired());
    });
  }

  /// 串行执行启停，且在执行时重新读取目标态：扫码成功 → 清空 → 切 tab
  /// 这类连续事件只会有一次最终判定，不会出现 start/stop 抖动。
  Future<void> _applyDesired() async {
    if (_applying) return;
    _applying = true;
    try {
      while (mounted) {
        final desired = cameraShouldRun(
          tabIndex: ref.read(tabIndexProvider),
          appResumed: _resumed,
          scan: ref.read(scanProvider),
        );
        final state = _controller.value;
        if (desired) {
          if (state.isRunning || state.isStarting) break;
          // 权限拒绝等错误不自动反复重试，等用户点「重试」
          if (state.error != null && !_retryRequested) break;
          _retryRequested = false;
          try {
            await _controller.start();
          } on MobileScannerException {
            break;
          }
          continue;
        }
        if (state.isRunning) {
          try {
            await _controller.stop();
          } on MobileScannerException {
            // 已释放/disposed 时不影响后续同步
          }
          continue;
        }
        break;
      }
    } finally {
      _applying = false;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    // onDetect 订阅在 MobileScanner 初始化时固定，运行时闸门只能放在回调里
    if (ref.read(scanProvider) is! ScanIdle) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    unawaited(_handleBarcode(raw));
  }

  Future<void> _handleBarcode(String raw) async {
    String? saveError;
    try {
      await ref.read(scanProvider.notifier).onBarcode(raw);
    } catch (e) {
      saveError = '$e';
    }
    if (!mounted) return;
    final scan = ref.read(scanProvider);
    if (scan is ScanFailure) {
      _notify('无法识别：${scan.message}');
      // 2 秒后自动恢复相机，无需用户手动点「继续扫码」
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && ref.read(scanProvider) is ScanFailure) _resume();
      });
    } else if (saveError != null) {
      _notify('二维码已识别，但保存记录失败：$saveError');
    }
  }

  void _resume() => ref.read(scanProvider.notifier).clear();

  void _retryCamera() {
    _retryRequested = true;
    _scheduleSync();
  }

  Future<void> _openAppSettings() async {
    final ok = await SystemChannel.openAppSettings();
    if (!ok && mounted) {
      _notify('无法打开系统设置，请手动进入 设置 > 应用 > 权限 授予相机权限');
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startVpn(ProxyConfig config) async {
    try {
      await runVpnAction(
        ref.read(vpnActionProvider.notifier),
        VpnAction.starting,
        () => ref.read(vpnControllerProvider).start(config),
      );
      if (!mounted) return;
      _notify('代理转发已启动：${config.upstream}');
      ref.read(scanProvider.notifier).clear();
      ref.read(tabIndexProvider.notifier).state = 1;
    } on VpnEngineException catch (e) {
      _notify(vpnErrorText(e.code, e.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanProvider);
    final busy = ref.watch(vpnActionProvider) == VpnAction.starting;

    ref.listen<int>(tabIndexProvider, (_, _) => _scheduleSync());
    ref.listen<ScanState>(scanProvider, (_, _) => _scheduleSync());

    return Stack(
      children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        if (scan is ScanIdle)
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final error = state.error;
              if (error != null) {
                return _CameraErrorOverlay(
                  error: error,
                  onOpenSettings: _openAppSettings,
                  onRetry: _retryCamera,
                );
              }
              return const _IdleHint();
            },
          )
        else
          _ResultOverlay(
            scan: scan,
            busy: busy,
            onResume: _resume,
            onStart: scan is ScanSuccess && !scan.loopbackWarning && !busy
                ? () => _startVpn(scan.config)
                : null,
          ),
      ],
    );
  }
}

class _IdleHint extends StatelessWidget {
  const _IdleHint();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          '对准 Burp 代理配置二维码',
          style: TextStyle(color: Colors.white70, fontSize: 16),
        ),
      ),
    );
  }
}

class _CameraErrorOverlay extends StatelessWidget {
  const _CameraErrorOverlay({
    required this.error,
    required this.onOpenSettings,
    required this.onRetry,
  });

  final MobileScannerException error;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final detail = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        '需要相机权限才能扫描二维码。\n请在系统设置中允许本应用使用相机，然后回来重试。',
      MobileScannerErrorCode.unsupported => '当前设备不支持相机扫码。',
      _ => '相机启动失败。\n请确认没有其它应用占用相机，然后重试。',
    };

    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography, color: Colors.orange, size: 64),
          const SizedBox(height: 16),
          const Text('相机不可用', style: TextStyle(color: Colors.orange, fontSize: 22)),
          const SizedBox(height: 12),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              if (denied)
                OutlinedButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('去设置'),
                ),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultOverlay extends StatelessWidget {
  const _ResultOverlay({
    required this.scan,
    required this.busy,
    required this.onResume,
    this.onStart,
  });

  final ScanState scan;
  final bool busy;
  final VoidCallback onResume;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final (icon, title, detail, color) = switch (scan) {
      ScanSuccess(:final config, :final wanWarning, :final loopbackWarning) => (
          loopbackWarning ? Icons.error : Icons.check_circle,
          loopbackWarning ? '地址不可用' : '解析成功',
          loopbackWarning
              ? '代理地址：${config.upstream}\n\n${config.host} 是手机本机地址，Burp 代理并不在手机上，启动后必然连不上。\n\n请在 Burp 代理监听器绑定电脑局域网 IP（或全部接口），用插件重新生成二维码后再扫。'
              : wanWarning
                  ? '代理地址：${config.upstream}\n\n提示：目标似乎不在局域网，请确认 Burp 代理地址正确。'
                  : '代理地址：${config.upstream}',
          loopbackWarning ? Colors.red : Colors.green,
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
              onPressed: busy ? null : onStart,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.vpn_lock),
              label: Text(busy ? '正在启动…' : '启动代理'),
            ),
            const SizedBox(height: 12),
          ],
          if (!busy)
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
