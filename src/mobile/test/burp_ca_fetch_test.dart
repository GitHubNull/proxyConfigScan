import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/ca/burp_ca_fetch.dart';
import 'package:proxy_config_scan/util/proxy_uri_validator.dart';

/// 本地 HttpServer 模拟 Burp 代理：收到 absolute-URI 请求后按目标端点回包。
void main() {
  late HttpServer server;

  ProxyConfig proxyConfig() => ProxyConfig.fromHostPort('127.0.0.1', server.port);

  Future<HttpServer> startProxy(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    httpServer.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        // 客户端超时断开后写响应会抛，测试中忽略
      }
    });
    return httpServer;
  }

  void respond(HttpRequest request, List<int> bytes, {int status = 200}) {
    request.response.statusCode = status;
    request.response.add(bytes);
    request.response.close();
  }

  test('首选端点返回 200 时直接返回证书字节', () async {
    final payload = List<int>.generate(256, (i) => i & 0xFF);
    server = await startProxy((request) {
      respond(request, payload);
    });
    addTearDown(() => server.close(force: true));

    final result = await fetchBurpCaCertificate(proxyConfig());
    expect(result, payload);
  });

  test('首选端点非 200 时回落到 burpsuite/cert', () async {
    final payload = List<int>.generate(300, (i) => (i * 3) & 0xFF);
    final targets = <String>[];
    server = await startProxy((request) {
      final target = request.uri.toString();
      targets.add(target);
      if (target.contains('burpsuite')) {
        respond(request, payload);
      } else {
        respond(request, const [], status: 404);
      }
    });
    addTearDown(() => server.close(force: true));

    final result = await fetchBurpCaCertificate(proxyConfig());
    expect(result, payload);
    expect(targets.any((t) => t.contains('burpsuite')), isTrue);
  });

  test('响应超过 64 KiB 时报体积异常', () async {
    server = await startProxy((request) {
      respond(request, List<int>.filled(70 * 1024, 0x30));
    });
    addTearDown(() => server.close(force: true));

    await expectLater(
      fetchBurpCaCertificate(proxyConfig()),
      throwsA(
        isA<CaFetchException>()
            .having((e) => e.message, 'message', contains('体积异常')),
      ),
    );
  });

  test('响应不足 64 字节时报内容过短', () async {
    server = await startProxy((request) {
      respond(request, List<int>.filled(32, 0x30));
    });
    addTearDown(() => server.close(force: true));

    await expectLater(
      fetchBurpCaCertificate(proxyConfig()),
      throwsA(
        isA<CaFetchException>()
            .having((e) => e.message, 'message', contains('过短')),
      ),
    );
  });

  test('代理端口未监听时报连不上', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    final config = ProxyConfig.fromHostPort('127.0.0.1', closedPort);

    await expectLater(
      fetchBurpCaCertificate(config),
      throwsA(
        isA<CaFetchException>()
            .having((e) => e.message, 'message', contains('连不上 Burp 代理')),
      ),
    );
  });

  test('代理迟迟不响应时报超时', () async {
    server = await startProxy((request) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      respond(request, List<int>.filled(128, 0x30));
    });
    addTearDown(() => server.close(force: true));

    await expectLater(
      fetchBurpCaCertificate(
        proxyConfig(),
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<CaFetchException>()
            .having((e) => e.message, 'message', contains('超时')),
      ),
    );
  });
}
