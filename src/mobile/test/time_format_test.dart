import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/util/time_format.dart';

void main() {
  test('同一天显示 今天 HH:mm', () {
    final now = DateTime(2026, 11, 6, 15, 30);
    final millis = DateTime(2026, 11, 6, 9, 5).millisecondsSinceEpoch;
    expect(formatScanTime(millis, now: now), '今天 09:05');
  });

  test('跨天显示 M-dd HH:mm', () {
    final now = DateTime(2026, 11, 6, 15, 30);
    final millis = DateTime(2026, 1, 2, 23, 59).millisecondsSinceEpoch;
    expect(formatScanTime(millis, now: now), '1-02 23:59');
  });

  test('跨年按日期显示而不是今天', () {
    final now = DateTime(2027, 1, 1, 0, 5);
    final millis = DateTime(2026, 12, 31, 8, 0).millisecondsSinceEpoch;
    expect(formatScanTime(millis, now: now), '12-31 08:00');
  });
}
