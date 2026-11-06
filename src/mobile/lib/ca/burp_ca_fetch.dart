import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../util/proxy_uri_validator.dart';

class CaFetchException implements Exception {
  const CaFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

// Burp 内建证书端点的两个等价主机名，均需经代理访问
const _endpoints = ['http://burp/cert', 'http://burpsuite/cert'];
const _minBytes = 64;
const _maxBytes = 64 * 1024;

/// 经指定 Burp 代理下载 CA 证书（DER）。
///
/// HttpClient 设置 findProxy 后会向代理发送 absolute-URI 请求，
/// Burp 内建端点据此返回 PortSwigger CA。
Future<Uint8List> fetchBurpCaCertificate(
  ProxyConfig upstream, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'PROXY ${_formatHost(upstream.host)}:${upstream.port}')
    ..connectionTimeout = timeout;

  try {
    return await _fetch(client).timeout(timeout);
  } on TimeoutException {
    throw const CaFetchException('获取证书超时，请确认 Burp 监听器与网络可达');
  } on SocketException {
    throw CaFetchException('连不上 Burp 代理（${upstream.upstream}）');
  } on CaFetchException {
    rethrow;
  } on HttpException catch (e) {
    throw CaFetchException('获取证书失败：${e.message}');
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _fetch(HttpClient client) async {
  CaFetchException? lastError;
  for (final endpoint in _endpoints) {
    final request = await client.getUrl(Uri.parse(endpoint));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain();
      lastError = CaFetchException('Burp 未返回证书（HTTP ${response.statusCode}）');
      continue;
    }
    final bytes = await _readLimited(response);
    if (bytes.length < _minBytes) {
      lastError = const CaFetchException('Burp 返回的证书内容过短');
      continue;
    }
    return bytes;
  }
  throw lastError ?? const CaFetchException('无法从 Burp 获取 CA 证书');
}

Future<Uint8List> _readLimited(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
    if (builder.length > _maxBytes) {
      throw const CaFetchException('证书体积异常（超过 64 KiB），已中止');
    }
  }
  return builder.takeBytes();
}

String _formatHost(String host) => host.contains(':') ? '[$host]' : host;
