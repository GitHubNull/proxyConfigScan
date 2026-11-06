import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/state/scan_state.dart';
import 'package:proxy_config_scan/util/camera_policy.dart';
import 'package:proxy_config_scan/util/proxy_uri_validator.dart';

void main() {
  const idle = ScanIdle();
  const success = ScanSuccess(
    ProxyConfig(host: '192.168.1.10', port: 8080, isLanHost: true),
  );
  const failure = ScanFailure('无法识别的二维码格式');

  test('相机仅在 扫码tab + 前台 + 等待扫码 时运行', () {
    for (final tab in [0, 1, 2]) {
      for (final resumed in [true, false]) {
        for (final scan in <ScanState>[idle, success, failure]) {
          expect(
            cameraShouldRun(tabIndex: tab, appResumed: resumed, scan: scan),
            tab == 0 && resumed && scan is ScanIdle,
            reason: 'tab=$tab resumed=$resumed scan=${scan.runtimeType}',
          );
        }
      }
    }
  });
}
