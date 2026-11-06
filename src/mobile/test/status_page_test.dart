import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/ca/ca_state.dart';
import 'package:proxy_config_scan/data/proxy_history_db.dart';
import 'package:proxy_config_scan/state/last_scan_state.dart';
import 'package:proxy_config_scan/state/vpn_state.dart';
import 'package:proxy_config_scan/system/system_channel.dart';
import 'package:proxy_config_scan/ui/widgets/ca_card.dart';
import 'package:proxy_config_scan/util/proxy_uri_validator.dart';
import 'package:proxy_config_scan/vpn/proxy_engine.dart' as engine;

class _FakeCaNotifier extends CaNotifier {
  _FakeCaNotifier(this._initial);

  final CaUiState _initial;
  int installCalls = 0;

  @override
  CaUiState build() => _initial;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> install() async {
    installCalls++;
  }
}

class _FakeLastScanNotifier extends LastScanNotifier {
  _FakeLastScanNotifier(this._value);

  final LastScan? _value;

  @override
  Future<LastScan?> build() async => _value;
}

class _FakeEngine implements engine.ProxyEngine {
  @override
  Future<void> start(ProxyConfig config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<engine.VpnSnapshot> status() async =>
      const engine.VpnSnapshot(lifecycle: engine.VpnLifecycle.idle);

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> clearError() async {}

  @override
  Stream<engine.VpnNativeEvent> get events => const Stream.empty();
}

void main() {
  const savedScan = LastScan(host: '192.168.1.10', port: 8080, scannedAt: 0);

  Future<_FakeCaNotifier> pumpCard(
    WidgetTester tester, {
    required CaUiState ca,
    LastScan? lastScan,
  }) async {
    final notifier = _FakeCaNotifier(ca);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          caProvider.overrideWith(() => notifier),
          lastScanProvider.overrideWith(() => _FakeLastScanNotifier(lastScan)),
          vpnControllerProvider.overrideWithValue(VpnController(_FakeEngine())),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: CaCard())),
        ),
      ),
    );
    await tester.pump();
    return notifier;
  }

  testWidgets('无最近扫码时禁用安装并提示先扫码', (tester) async {
    await pumpCard(
      tester,
      ca: const CaUiState(
        stage: CaStage.idle,
        status: CaStatus(supported: true, installed: false),
      ),
    );

    expect(find.text('未安装'), findsOneWidget);
    expect(find.text('请先扫码或启动代理，再安装证书。'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '安装 Burp CA'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('已安装时显示 subject 与指纹入口', (tester) async {
    await pumpCard(
      tester,
      ca: const CaUiState(
        stage: CaStage.idle,
        status: CaStatus(
          supported: true,
          installed: true,
          subject: 'CN=PortSwigger CA',
          fingerprintSha256: 'AA:BB:CC',
        ),
      ),
    );

    expect(find.text('已安装'), findsOneWidget);
    expect(find.text('已安装：CN=PortSwigger CA'), findsOneWidget);
    expect(find.text('证书指纹（SHA-256）'), findsOneWidget);
    expect(find.text('重新检测'), findsOneWidget);
  });

  testWidgets('saved 状态显示下载路径与安全设置入口', (tester) async {
    await pumpCard(
      tester,
      ca: const CaUiState(
        stage: CaStage.saved,
        status: CaStatus(supported: true, installed: false),
        fileName: 'BurpSuite-CA.cer',
      ),
      lastScan: savedScan,
    );

    expect(find.text('已保存到 下载/BurpSuite-CA.cer'), findsOneWidget);
    expect(find.text('打开安全设置'), findsOneWidget);
    expect(find.text('重新检测'), findsOneWidget);
  });

  testWidgets('shared 状态显示 iOS 文件安装引导', (tester) async {
    await pumpCard(
      tester,
      ca: const CaUiState(
        stage: CaStage.shared,
        status: CaStatus(supported: true),
        fileName: 'BurpSuite-CA.cer',
      ),
      lastScan: savedScan,
    );

    expect(find.textContaining('存储到“文件”'), findsOneWidget);
    expect(find.textContaining('证书信任设置'), findsOneWidget);
    expect(find.text('无法检测'), findsOneWidget);
  });

  testWidgets('error 状态显示错误文案与重试', (tester) async {
    final notifier = await pumpCard(
      tester,
      ca: const CaUiState(
        stage: CaStage.error,
        status: CaStatus(supported: true, installed: false),
        error: '连不上 Burp 代理（192.168.1.10:8080）',
      ),
      lastScan: savedScan,
    );

    expect(find.text('连不上 Burp 代理（192.168.1.10:8080）'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(notifier.installCalls, 1);
  });

  testWidgets('安装前确认弹窗显示目标并仅在继续时调用 install', (tester) async {
    final notifier = await pumpCard(
      tester,
      ca: const CaUiState(
        stage: CaStage.idle,
        status: CaStatus(supported: true, installed: false),
      ),
      lastScan: savedScan,
    );

    await tester.tap(find.text('安装 Burp CA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('192.168.1.10:8080'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(notifier.installCalls, 0);

    await tester.tap(find.text('安装 Burp CA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(notifier.installCalls, 1);
  });
}
