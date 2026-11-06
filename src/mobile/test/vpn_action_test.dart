import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/state/vpn_state.dart';

void main() {
  group('runVpnAction', () {
    test('执行期间状态为动作值，结束后复位 none', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(vpnActionProvider.notifier);

      final during = <VpnAction>[];
      await runVpnAction(notifier, VpnAction.starting, () async {
        during.add(container.read(vpnActionProvider));
      });

      expect(during, [VpnAction.starting]);
      expect(container.read(vpnActionProvider), VpnAction.none);
    });

    test('body 抛异常时复位 none 且异常原样上抛', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(vpnActionProvider.notifier);

      await expectLater(
        runVpnAction(
          notifier,
          VpnAction.stopping,
          () async => throw StateError('boom'),
        ),
        throwsStateError,
      );
      expect(container.read(vpnActionProvider), VpnAction.none);
    });
  });
}
