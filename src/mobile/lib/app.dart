import 'package:flutter/material.dart';

import 'ui/pages/history_page.dart';
import 'ui/pages/scan_page.dart';
import 'ui/pages/status_page.dart';

/// 应用根组件：底部导航三页（扫码 / 状态 / 历史）。
class ProxyScanApp extends StatefulWidget {
  const ProxyScanApp({super.key});

  @override
  State<ProxyScanApp> createState() => _ProxyScanAppState();
}

class _ProxyScanAppState extends State<ProxyScanApp> {
  int _index = 0;

  static const _titles = ['扫码配置', '运行状态', '历史记录'];
  static const _pages = [ScanPage(), StatusPage(), HistoryPage()];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '抓包代理配置',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: Scaffold(
        appBar: AppBar(title: Text(_titles[_index])),
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
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
