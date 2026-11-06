import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_config_scan/util/proxy_uri_validator.dart';

void main() {
  group('合法用例', () {
    final cases = <String, ProxyConfig>{
      'http://192.168.1.10:8080':
          ProxyConfig(host: '192.168.1.10', port: 8080, isLanHost: true),
      'http://192.168.1.10':
          ProxyConfig(host: '192.168.1.10', port: 8080, isLanHost: true),
      'http://10.0.0.1:9090':
          ProxyConfig(host: '10.0.0.1', port: 9090, isLanHost: true),
      'http://172.16.5.5:8080':
          ProxyConfig(host: '172.16.5.5', port: 8080, isLanHost: true),
      'http://172.31.255.255:1':
          ProxyConfig(host: '172.31.255.255', port: 1, isLanHost: true),
      'http://127.0.0.1:8080':
          ProxyConfig(host: '127.0.0.1', port: 8080, isLanHost: true),
      'http://169.254.1.1:8080':
          ProxyConfig(host: '169.254.1.1', port: 8080, isLanHost: true),
      'http://8.8.8.8:8080':
          ProxyConfig(host: '8.8.8.8', port: 8080, isLanHost: false),
      'http://proxy.lan:8080':
          ProxyConfig(host: 'proxy.lan', port: 8080, isLanHost: true),
      'http://burp-server.local:3128':
          ProxyConfig(host: 'burp-server.local', port: 3128, isLanHost: true),
      'http://example.com:65535':
          ProxyConfig(host: 'example.com', port: 65535, isLanHost: false),
      'HTTP://192.168.0.1:8080':
          ProxyConfig(host: '192.168.0.1', port: 8080, isLanHost: true),
      // 裸 host:port 容错
      '192.168.1.10:8080':
          ProxyConfig(host: '192.168.1.10', port: 8080, isLanHost: true),
    };

    cases.forEach((input, expected) {
      test('$input → ${expected.upstream}', () {
        final result = ProxyUriValidator.parse(input);
        expect(result.host, expected.host);
        expect(result.port, expected.port);
        expect(result.isLanHost, expected.isLanHost);
      });
    });
  });

  group('非法用例', () {
    final cases = <String, String>{
      '': '二维码内容为空',
      '   ': '二维码内容为空',
      'https://192.168.1.10:8080': '暂不支持该类型',
      'socks5://192.168.1.10:1080': '暂不支持该类型',
      'ftp://192.168.1.10:8080': '无法识别的二维码格式',
      'http://192.168.300.1:8080': 'IP 地址不合法',
      'http://192.168.1:8080': 'IP 地址不合法',
      'http://256.1.1.1:8080': 'IP 地址不合法',
      'http://01.2.3.4:8080': 'IP 地址不合法',
      'http://192.168.1.10:0': '端口不合法',
      'http://192.168.1.10:70000': '端口不合法',
      'http://:8080': '无法识别的二维码格式',
      'http://-bad-.com:8080': '域名不合法',
      'http://bad..com:8080': '域名不合法',
      'http://${'a' * 250}.com:8080': '域名不合法',
      'http://user@192.168.1.10:8080': '不允许包含用户信息',
      '随便一段文字': '域名不合法',
    };

    cases.forEach((input, expectedMessage) {
      test('拒绝 $input', () {
        expect(
          () => ProxyUriValidator.parse(input),
          throwsA(isA<ProxyParseException>()),
        );
        try {
          ProxyUriValidator.parse(input);
          fail('应当抛出 ProxyParseException');
        } on ProxyParseException catch (e) {
          if (expectedMessage.startsWith('允许')) {
            fail('该用例实际合法，不应拒绝: $input');
          }
          expect(e.message, contains(expectedMessage.replaceFirst('（应为 1-65535）', '')));
        }
      });
    });
  });

  group('path/query 忽略', () {
    test('http://192.168.1.10:8080/path?x=1 解析成功', () {
      final result = ProxyUriValidator.parse('http://192.168.1.10:8080/path?x=1');
      expect(result.upstream, '192.168.1.10:8080');
    });
  });

  group('IPv6', () {
    test('http://[fe80::1]:8080 合法', () {
      final result = ProxyUriValidator.parse('http://[fe80::1]:8080');
      expect(result.host, 'fe80::1');
      expect(result.port, 8080);
      expect(result.isLanHost, isFalse);
    });

    test('http://[fe80::zzz]:8080 拒绝', () {
      expect(
        () => ProxyUriValidator.parse('http://[fe80::zzz]:8080'),
        throwsA(isA<ProxyParseException>()),
      );
    });
  });

  group('isLoopback 覆盖 127 全段与 IPv6 全写', () {
    test('回环判定 true', () {
      for (final host in [
        '127.0.0.1',
        '127.0.0.2',
        '127.10.20.30',
        'localhost',
        'LOCALHOST',
        '::1',
        '0:0:0:0:0:0:0:1',
      ]) {
        expect(ProxyUriValidator.isLoopback(host), isTrue, reason: host);
      }
    });

    test('非回环判定 false（含 isLanHost 把 127/8 算私网的边界）', () {
      for (final host in ['1278.0.0.1', '192.168.1.1', '10.0.0.1', '::2', '']) {
        expect(ProxyUriValidator.isLoopback(host), isFalse, reason: host);
      }
    });

    test('127.0.0.2 先于 isLanHost 命中回环（历史校验顺序不变式）', () {
      final host = '127.0.0.2';
      expect(ProxyUriValidator.isLoopback(host), isTrue);
      expect(ProxyUriValidator.isLanHost(host), isTrue);
    });
  });
}
