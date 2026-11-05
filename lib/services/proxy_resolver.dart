import 'dart:io';

/// 统一解析代理：用户手动填写 > 环境变量 > Windows 系统代理。
class ProxyResolver {
  ProxyResolver._();

  static bool _checked = false;
  static String? _systemProxy;

  static void reset() {
    _checked = false;
    _systemProxy = null;
  }

  /// 系统代理存在但实测不通时调用，本次运行不再重复探测。
  static void disableSystemProxy() {
    _checked = true;
    _systemProxy = null;
  }

  static String normalize(String raw) {
    var value = raw.trim();
    final scheme = value.indexOf('://');
    if (scheme >= 0) value = value.substring(scheme + 3);
    final slash = value.indexOf('/');
    if (slash >= 0) value = value.substring(0, slash);
    return value.trim();
  }

  static Future<String?> resolve({String? explicit}) async {
    final manual = normalize(explicit ?? '');
    if (manual.isNotEmpty) return manual;
    return _detectSystemProxy();
  }

  static Future<String?> _detectSystemProxy() async {
    if (_checked) return _systemProxy;
    _checked = true;

    final env =
        (Platform.environment['HTTPS_PROXY'] ??
                Platform.environment['https_proxy'] ??
                Platform.environment['ALL_PROXY'] ??
                Platform.environment['all_proxy'] ??
                '')
            .trim();
    if (env.isNotEmpty) {
      _systemProxy = normalize(env);
      return _systemProxy;
    }
    if (!Platform.isWindows) return null;

    try {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final enabled = await Process.run('reg', [
        'query',
        key,
        '/v',
        'ProxyEnable',
      ]).timeout(const Duration(seconds: 2));
      if (enabled.exitCode != 0 ||
          !RegExp(
            r'ProxyEnable\s+REG_DWORD\s+0x1',
            caseSensitive: false,
          ).hasMatch('${enabled.stdout}')) {
        return null;
      }
      final server = await Process.run('reg', [
        'query',
        key,
        '/v',
        'ProxyServer',
      ]).timeout(const Duration(seconds: 2));
      final text = '${server.stdout}';
      final match = RegExp(
        r'ProxyServer\s+REG_SZ\s+(.+)$',
        multiLine: true,
      ).firstMatch(text);
      var value = match?.group(1)?.trim() ?? '';
      if (value.contains('=')) {
        final entries = <String, String>{};
        for (final part in value.split(';')) {
          final index = part.indexOf('=');
          if (index <= 0) continue;
          entries[part.substring(0, index).toLowerCase()] = part
              .substring(index + 1)
              .trim();
        }
        value = entries['https'] ?? entries['http'] ?? '';
      }
      if (value.isNotEmpty && !value.toLowerCase().startsWith('socks')) {
        _systemProxy = normalize(value);
      }
    } catch (_) {
      // 读注册表失败不影响直连
    }
    return _systemProxy;
  }
}
