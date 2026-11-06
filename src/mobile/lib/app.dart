import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/app_state.dart';
import 'ui/pages/history_page.dart';
import 'ui/pages/scan_page.dart';
import 'ui/pages/status_page.dart';

/// 应用根组件：底部导航三页（扫码 / 状态 / 历史）。
/// 页索引由 [tabIndexProvider] 持有，扫码/历史页可主动跳转到状态页。
class ProxyScanApp extends ConsumerWidget {
  const ProxyScanApp({super.key});

  static const _titles = ['扫码配置', '运行状态', '历史记录'];
  static const _pages = [ScanPage(), StatusPage(), HistoryPage()];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(tabIndexProvider);
    return MaterialApp(
      title: '抓包代理配置',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: Scaffold(
        appBar: AppBar(title: Text(_titles[index])),
        body: IndexedStack(index: index, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) =>
              ref.read(tabIndexProvider.notifier).state = i,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.qr_code_scanner),
              label: '扫码',
            ),
            NavigationDestination(
              icon: Icon(Icons.monitor_heart),
              label: '状态',
            ),
            NavigationDestination(
              icon: Icon(Icons.history),
              label: '历史',
            ),
          ],
        ),
      ),
    );
  }
}
