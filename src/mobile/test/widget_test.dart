import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/app.dart';

void main() {
  testWidgets('应用骨架渲染：底部导航三页', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ProxyScanApp()));
    await tester.pump();

    expect(find.text('扫码配置'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
  });
}
