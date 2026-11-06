import '../state/scan_state.dart';

/// 相机唯一允许运行的组合：扫码 tab 可见、App 在前台、且处于等待扫码态。
/// 三页由 IndexedStack 常驻，切 tab 不会触发 dispose，必须用该口径显式停相机。
bool cameraShouldRun({
  required int tabIndex,
  required bool appResumed,
  required ScanState scan,
}) =>
    tabIndex == 0 && appResumed && scan is ScanIdle;
