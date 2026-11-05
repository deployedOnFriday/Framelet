import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/proxy_resolver.dart';
import 'package:framelet/services/update_service.dart';

void main() {
  test('版本比较只看三段数字', () {
    expect(UpdateService.isNewer('0.1.6', '0.1.5'), isTrue);
    expect(UpdateService.isNewer('0.2.0', '0.1.9'), isTrue);
    expect(UpdateService.isNewer('0.1.5', '0.1.5'), isFalse);
    expect(UpdateService.isNewer('0.1.4', '0.1.5'), isFalse);
    expect(UpdateService.isNewer('1.0', '0.9.9'), isTrue);
  });

  test('代理地址去掉协议和路径', () {
    expect(ProxyResolver.normalize('http://127.0.0.1:7890/'), '127.0.0.1:7890');
    expect(
      ProxyResolver.normalize('  https://proxy.local:8080/path  '),
      'proxy.local:8080',
    );
    expect(ProxyResolver.normalize(''), '');
  });
}
