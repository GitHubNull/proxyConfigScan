import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/proxy_history_db.dart';
import '../state/last_scan_state.dart';
import '../state/vpn_state.dart';
import '../system/system_channel.dart';
import '../util/proxy_uri_validator.dart';
import 'burp_ca_fetch.dart';

/// CA 卡片阶段。`saved`/`launched`/`shared` 都是“证书已交给系统/文件”的引导态，
/// 真正是否被信任需用户完成系统 UI 后靠 caStatus 复检。
enum CaStage { idle, checking, fetching, installing, saved, launched, shared, error }

class CaUiState {
  const CaUiState({
    this.stage = CaStage.idle,
    this.status,
    this.fileName,
    this.error,
  });

  final CaStage stage;
  final CaStatus? status;
  final String? fileName;
  final String? error;

  CaUiState copyWith({
    CaStage? stage,
    CaStatus? status,
    String? fileName,
    String? error,
    bool clearError = false,
  }) =>
      CaUiState(
        stage: stage ?? this.stage,
        status: status ?? this.status,
        fileName: fileName ?? this.fileName,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 安装目标：VPN 运行中的上游优先，否则用最近一次扫码。
ProxyConfig? caTargetFrom(VpnSnapshot vpn, LastScan? lastScan) {
  final upstream = vpn.upstream;
  if (vpn.isRunning && upstream != null) {
    try {
      return ProxyUriValidator.parse('http://$upstream');
    } on ProxyParseException {
      // 引擎上报格式异常时退回最近扫码
    }
  }
  return lastScan?.toConfig();
}

String caErrorText(CaException e) => switch (e.code) {
      'CA_INVALID_CERT' => '代理返回的不是有效证书，请确认目标确实是 Burp 代理',
      'CA_UNSUPPORTED' => '系统不支持直接打开证书安装器，请按页面步骤手动安装',
      'CA_STORAGE_FAILED' => '证书保存到下载目录失败，请检查存储空间与权限',
      _ => '操作失败：${e.message}',
    };

class CaNotifier extends Notifier<CaUiState> {
  @override
  CaUiState build() => const CaUiState();

  ProxyConfig? _target() => caTargetFrom(
        ref.read(vpnControllerProvider).current,
        ref.read(lastScanProvider).valueOrNull,
      );

  /// 复检安装状态；已安装时静默刷新，不闪 spinner。
  Future<void> refresh() async {
    if (state.stage == CaStage.fetching || state.stage == CaStage.installing) {
      return;
    }
    if (state.status == null) {
      state = state.copyWith(stage: CaStage.checking, clearError: true);
    }
    try {
      final status = await SystemChannel.caStatus();
      final keepGuide = state.stage == CaStage.saved ||
          state.stage == CaStage.launched ||
          state.stage == CaStage.shared;
      state = CaUiState(
        stage: status.installed == true || !keepGuide ? CaStage.idle : state.stage,
        status: status,
        fileName: state.fileName,
      );
    } on CaException catch (e) {
      state = state.copyWith(stage: CaStage.error, error: caErrorText(e));
    }
  }

  Future<void> install() async {
    if (state.stage == CaStage.fetching || state.stage == CaStage.installing) {
      return;
    }
    final target = _target();
    if (target == null) {
      state = state.copyWith(
        stage: CaStage.error,
        error: '请先扫码或启动代理，再安装证书',
      );
      return;
    }
    state = state.copyWith(stage: CaStage.fetching, clearError: true);
    final Uint8List bytes;
    try {
      bytes = await fetchBurpCaCertificate(target);
    } on CaFetchException catch (e) {
      state = state.copyWith(stage: CaStage.error, error: e.message);
      return;
    }
    state = state.copyWith(stage: CaStage.installing);
    try {
      final result = await SystemChannel.installCa(
        bytes,
        name: 'PortSwigger CA',
      );
      state = CaUiState(
        stage: switch (result.state) {
          'launched' => CaStage.launched,
          'shared' => CaStage.shared,
          _ => CaStage.saved,
        },
        status: state.status,
        fileName: result.fileName,
      );
    } on CaException catch (e) {
      state = state.copyWith(stage: CaStage.error, error: caErrorText(e));
    }
  }
}

final caProvider = NotifierProvider<CaNotifier, CaUiState>(CaNotifier.new);
