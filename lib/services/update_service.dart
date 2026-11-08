import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'proxy_resolver.dart';

/// 应用内检查更新（GitHub Releases）。
///
/// 检查走 api.github.com；安装包下载会先并发测速 GitHub 直连与
/// 国内常用镜像，再用多连接分段下载，避免单连接被限速。
class UpdateService {
  UpdateService._();

  static const _repo = 'deployedOnFriday/Framelet';
  static const _userAgent = 'Framelet/0.1 (updater)';

  /// 可选代理（与刮削代理共用配置；空则自动探测系统代理）。
  static String? proxyAddress;

  /// GitHub Release 资产加速前缀。只拼接 GitHub 官方下载地址，
  /// 不经过任何账号信息。
  static const _mirrors = <String>[
    'https://gh.monlor.com/',
    'https://gh.meali.top/',
    'https://ghgo.de5.net/',
    'https://gh.chjina.com/',
    'https://ghpxy.hwinzniej.top/',
  ];

  static Future<String?> _activeProxy() =>
      ProxyResolver.resolve(explicit: proxyAddress);

  static HttpClient _httpClient(String? proxy) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = _userAgent;
    final effective = ProxyResolver.normalize(proxy ?? '');
    if (effective.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $effective';
    }
    return client;
  }

  /// 最新 Release 信息；无网络/接口异常时返回 null。
  ///
  /// 代理与直连并发竞速取先成功者——串行重试在代理半死时会
  /// 先挂满 10 秒再等直连 10 秒，用户看起来就是「卡住」。
  static Future<ReleaseInfo?> checkLatest() async {
    final proxy = await _activeProxy();
    if (proxy == null) return _fetchLatest(null);
    final results = await Future.wait([
      _fetchLatest(proxy),
      _fetchLatest(null),
    ]);
    return results.firstWhere((info) => info != null, orElse: () => null);
  }

  static Future<ReleaseInfo?> _fetchLatest(String? proxy) async {
    final client = _httpClient(proxy);
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
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
      final parts = v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
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

  static List<String> _candidateUrls(String url) => [
    url,
    for (final mirror in _mirrors) '$mirror$url',
  ];

  /// 并发探测每个下载线路的首字节耗时，按从快到慢返回可用线路。
  static Future<List<({String url, int ms, bool ranged})>> _probeCandidates(
    List<String> urls,
    String? proxy,
  ) async {
    final results = await Future.wait(
      urls.map((url) async {
        final ranged = await _probeLatency(url, proxy, ranged: true);
        final plain = ranged == null
            ? await _probeLatency(url, proxy, ranged: false)
            : null;
        final probe = ranged ?? plain;
        if (probe == null) return null;
        return (url: url, ms: probe.ms, ranged: ranged?.status == 206);
      }),
    );
    final valid =
        results.whereType<({String url, int ms, bool ranged})>().toList()
          ..sort((a, b) => a.ms.compareTo(b.ms));
    return valid;
  }

  /// 测速只等首个数据块就断开：部分镜像会忽略 Range 直接返回 200，
  /// 若用 drain() 会把整个安装包拖完，测速反而变成全量下载。
  static Future<({int ms, int status})?> _probeLatency(
    String url,
    String? proxy, {
    required bool ranged,
  }) async {
    final watch = Stopwatch()..start();
    HttpClient? client;
    try {
      client = _httpClient(proxy);
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (ranged) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        return null;
      }
      await response.first.timeout(const Duration(seconds: 5));
      return (ms: watch.elapsedMilliseconds, status: response.statusCode);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// 下载安装包到临时目录，返回落盘路径。
  ///
  /// 大于 8MB 的包会拆成 2~6 段并发下载；任一线路失败会自动换
  /// 下一个镜像。最终校验文件大小，避免半包被当成安装程序。
  static Future<String?> download(
    ({String name, String url, int size}) asset, {
    void Function(double progress)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    var proxy = await _activeProxy();
    final candidates = _candidateUrls(asset.url);

    onStatus?.call('正在测速下载线路…');
    var probes = await _probeCandidates(candidates, proxy);
    if (probes.isEmpty && proxy != null) {
      if ((proxyAddress ?? '').trim().isEmpty) {
        ProxyResolver.disableSystemProxy();
      }
      proxy = null;
      probes = await _probeCandidates(candidates, proxy);
    }
    final ordered = <String>[
      for (final probe in probes) probe.url,
      ...candidates.where((url) => !probes.any((probe) => probe.url == url)),
    ];

    final file = File('${Directory.systemTemp.path}/${asset.name}');
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}

    final total = asset.size;
    if (total >= 8 * 1024 * 1024 && probes.any((probe) => probe.ranged)) {
      onStatus?.call('正在多线程下载 ${asset.name}…');
      final ok = await _downloadSegmented(
        file,
        ordered,
        total,
        proxy,
        onProgress,
      );
      if (ok &&
          file.existsSync() &&
          file.lengthSync() == total &&
          _validInstaller(file, asset.name)) {
        return file.path;
      }
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }

    onStatus?.call('正在下载 ${asset.name}…');
    final ok = await _downloadSingle(
      file,
      ordered,
      total,
      proxy,
      onProgress,
      asset.name,
    );
    if (ok &&
        file.existsSync() &&
        file.lengthSync() >= 1024 &&
        (total <= 0 || file.lengthSync() == total) &&
        _validInstaller(file, asset.name)) {
      return file.path;
    }
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    return null;
  }

  /// 防止镜像返回同尺寸的 HTML 错误页被当成安装包。
  static bool _validInstaller(File file, String name) {
    try {
      final raf = file.openSync();
      final head = raf.readSync(4);
      raf.closeSync();
      if (name.toLowerCase().endsWith('.exe')) {
        return head.length >= 2 && head[0] == 0x4D && head[1] == 0x5A;
      }
      if (name.toLowerCase().endsWith('.zip') ||
          name.toLowerCase().endsWith('.apk')) {
        return head.length >= 2 && head[0] == 0x50 && head[1] == 0x4B;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _downloadSegmented(
    File file,
    List<String> urls,
    int total,
    String? proxy,
    void Function(double progress)? onProgress,
  ) async {
    final connections = total >= 40 * 1024 * 1024
        ? 6
        : total >= 16 * 1024 * 1024
        ? 4
        : 2;
    final chunk = (total / connections).ceil();
    final raf = await file.open(mode: FileMode.write);
    var received = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);

    void report(int delta) {
      received += delta;
      final now = DateTime.now();
      if (now.difference(lastReport) < const Duration(milliseconds: 120)) {
        return;
      }
      lastReport = now;
      onProgress?.call((received / total).clamp(0.0, 1.0));
    }

    try {
      final tasks = <Future<void>>[];
      for (var i = 0; i < connections; i++) {
        final start = i * chunk;
        if (start >= total) break;
        final end = math.min(total - 1, start + chunk - 1);
        tasks.add(() async {
          final ok = await _downloadSegment(
            raf,
            urls,
            start,
            end,
            proxy,
            report,
          );
          if (!ok) throw StateError('segment failed');
        }());
      }
      await Future.wait(tasks);
      await raf.flush();
      if (received == total) {
        onProgress?.call(1.0);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      await raf.close();
    }
  }

  static Future<bool> _downloadSegment(
    RandomAccessFile raf,
    List<String> urls,
    int start,
    int end,
    String? proxy,
    void Function(int delta) report,
  ) async {
    final expected = end - start + 1;
    for (final url in urls) {
      HttpClient? client;
      var written = 0;
      try {
        client = _httpClient(proxy);
        final request = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode != 206) {
          try {
            await response.drain<void>();
          } catch (_) {}
          continue;
        }
        final length = response.contentLength;
        if (length > 0 && length != expected) {
          try {
            await response.drain<void>();
          } catch (_) {}
          continue;
        }
        await for (final chunk in response.timeout(
          const Duration(seconds: 25),
        )) {
          raf.setPositionSync(start + written);
          raf.writeFromSync(chunk);
          written += chunk.length;
          report(chunk.length);
          if (written > expected) break;
        }
        if (written == expected) return true;
        if (written > 0) {
          report(-written);
          written = 0;
        }
      } catch (_) {
        if (written > 0) {
          report(-written);
          written = 0;
        }
      } finally {
        client?.close(force: true);
      }
    }
    return false;
  }

  static Future<bool> _downloadSingle(
    File file,
    List<String> urls,
    int total,
    String? proxy,
    void Function(double progress)? onProgress,
    String name,
  ) async {
    for (final url in urls) {
      HttpClient? client;
      IOSink? sink;
      try {
        client = _httpClient(proxy);
        final request = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode != 200) {
          try {
            await response.drain<void>();
          } catch (_) {}
          continue;
        }
        final expected = response.contentLength > 0
            ? response.contentLength
            : total;
        sink = file.openWrite();
        var received = 0;
        await for (final chunk in response.timeout(
          const Duration(seconds: 25),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (expected > 0) {
            onProgress?.call((received / expected).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (expected > 0 && received != expected) continue;
        // 镜像可能用 200 返回 HTML 错误页，头校验不过就换下一家。
        if (received >= 1024 && _validInstaller(file, name)) return true;
      } catch (_) {
        // 换下一条线路
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        client?.close(force: true);
      }
    }
    return false;
  }

  /// 启动安装包（Windows：Inno 向导会自动处理正在运行的应用；
  /// macOS：挂载 dmg）。
  static Future<void> launch(String path) async {
    if (Platform.isWindows) {
      await Process.start(path, const [], mode: ProcessStartMode.detached);
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
