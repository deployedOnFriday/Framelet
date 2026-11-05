import 'dart:convert';
import 'dart:io';

/// 应用内检查更新（GitHub Releases）。
///
/// 检查走 api.github.com（国内直连一般可达）；安装包下载走 Release
/// 资产的 302 链接。可选复用刮削代理（MediaLibrary.load 时注入）。
class UpdateService {
  UpdateService._();

  static const _repo = 'deployedOnFriday/Framelet';
  static const _userAgent = 'Framelet/0.1 (updater)';

  /// 可选代理（与刮削代理共用配置；空则直连）。
  static String? proxyAddress;

  static HttpClient _httpClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = _userAgent;
    final proxy = proxyAddress?.trim();
    if (proxy != null && proxy.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $proxy';
    }
    return client;
  }

  /// 最新 Release 信息；无网络/接口异常时返回 null。
  static Future<ReleaseInfo?> checkLatest() async {
    final client = _httpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, Object?>;
      return ReleaseInfo(
        version: (json['tag_name'] as String? ?? '').replaceFirst(
          RegExp('^v'),
          '',
        ),
        htmlUrl: json['html_url'] as String? ?? '',
        assets: [
          for (final asset in (json['assets'] as List? ?? const []))
            (
              name: (asset as Map)['name']! as String,
              url: asset['browser_download_url']! as String,
              size: (asset['size'] as num).toInt(),
            ),
        ],
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 三段式版本比较：remote > current 返回 true。
  static bool isNewer(String remote, String current) {
    List<int> parse(String v) {
      final parts = v
          .split('.')
          .map((p) => int.tryParse(p) ?? 0)
          .toList();
      while (parts.length < 3) {
        parts.add(0);
      }
      return parts.sublist(0, 3);
    }

    final r = parse(remote);
    final c = parse(current);
    for (var i = 0; i < 3; i++) {
      if (r[i] != c[i]) return r[i] > c[i];
    }
    return false;
  }

  /// 当前平台对应的安装包资产（iOS 未签名不提供应用内更新）。
  static ({String name, String url, int size})? assetForPlatform(
    ReleaseInfo info,
  ) {
    for (final asset in info.assets) {
      if (Platform.isWindows && asset.name.startsWith('FrameletSetup-')) {
        return asset;
      }
      if (Platform.isAndroid && asset.name.endsWith('.apk')) {
        return asset;
      }
      if (Platform.isMacOS && asset.name.endsWith('.dmg')) {
        return asset;
      }
    }
    return null;
  }

  /// 下载安装包到临时目录，返回落盘路径。
  static Future<String?> download(
    ({String name, String url, int size}) asset, {
    void Function(double progress)? onProgress,
  }) async {
    final client = _httpClient();
    try {
      final request = await client.getUrl(Uri.parse(asset.url));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) return null;
      final total = response.contentLength > 0
          ? response.contentLength
          : asset.size;
      final temp = Directory.systemTemp;
      final file = File('${temp.path}/${asset.name}');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.close();
      if (file.lengthSync() < 1024) {
        file.deleteSync();
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 启动安装包（Windows：Inno 向导会自动处理正在运行的应用；
  /// macOS：挂载 dmg）。
  static Future<void> launch(String path) async {
    if (Platform.isWindows) {
      await Process.start(
        path,
        const [],
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    }
  }
}

/// 一次检查更新的结果。
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.htmlUrl,
    required this.assets,
  });

  final String version;
  final String htmlUrl;
  final List<({String name, String url, int size})> assets;
}
