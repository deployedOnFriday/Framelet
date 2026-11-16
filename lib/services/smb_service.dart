import 'dart:io';

import '../models/media_source.dart';

/// 局域网 SMB 共享。
///
/// Windows 上不自己实现 SMB 协议：把共享当成本机 UNC 路径（`\\host\share`）
/// 交给系统，扫描走 Dart 的 `Directory`，播放交给 mpv，天然支持凭据、
/// 断线重连和系统级缓存。需要登录时用 `net use` 建立会话。
class SmbService {
  SmbService._();

  /// 统一成 UNC：`smb://host/share`、`//host/share`、`\\host\\share`
  /// 都归一为 `\\host\share`。
  static String normalizeAddress(String raw) {
    var value = raw.trim();
    if (value.toLowerCase().startsWith('smb://')) {
      value = value.substring('smb://'.length);
    }
    value = value.replaceAll('/', r'\');
    value = value.replaceAll(RegExp(r'\\+'), r'\');
    value = value.replaceFirst(RegExp(r'^\\'), '');
    value = value.replaceAll(RegExp(r'\\+$'), '');
    if (value.isEmpty) return '';
    return '\\\\$value';
  }

  /// 共享根（`\\host\share`），`net use` 只针对这一层建会话。
  static String shareRootOf(String address) {
    final normalized = normalizeAddress(address);
    final parts = normalized
        .replaceFirst(RegExp(r'^\\+'), '')
        .split(r'\')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2) return normalized;
    return '\\\\${parts[0]}\\${parts[1]}';
  }

  static Future<void> testConnection(
    MediaSource source,
    String password,
  ) async {
    await ensureAccessible(source, password);
  }

  /// 确认共享可读；必要时用账号密码建立系统会话。
  static Future<void> ensureAccessible(
    MediaSource source,
    String password,
  ) async {
    if (!Platform.isWindows) {
      throw const FileSystemException('SMB 共享通过系统挂载访问，当前平台请改用 WebDAV');
    }
    final address = normalizeAddress(source.address);
    if (address.isEmpty) {
      throw const FileSystemException('共享地址不能为空');
    }
    final directory = Directory(source.location);
    if (await _canList(directory)) return;

    final username = source.username.trim();
    if (username.isEmpty) {
      throw FileSystemException('无法访问共享。请填写用户名和密码，或先在系统里映射该共享', address);
    }
    final share = shareRootOf(address);
    final result = await Process.run('net', [
      'use',
      share,
      password,
      '/user:$username',
      '/persistent:no',
    ]);
    if (result.exitCode != 0) {
      final detail = '${result.stderr}'.trim();
      throw FileSystemException(
        detail.isEmpty ? 'SMB 登录失败' : 'SMB 登录失败：$detail',
        address,
      );
    }
    if (await _canList(directory)) return;
    throw FileSystemException('共享已登录，但目录不可读', source.location);
  }

  static Future<bool> _canList(Directory directory) async {
    try {
      if (!await directory.exists()) return false;
      await directory.list(followLinks: false).take(1).toList();
      return true;
    } catch (_) {
      return false;
    }
  }
}
