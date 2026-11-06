import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底部导航当前页索引（0 扫码 / 1 状态 / 2 历史）。
/// 提升为 provider 供跨页跳转：扫码/历史启动成功后自动切到状态页。
final tabIndexProvider = StateProvider<int>((_) => 0);
