import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 用 Windows 凭据隔离机制（DPAPI）保存敏感信息：
/// - key `framelet.sources`        -> 媒体源配置 JSON（地址、用户名等非敏感项）
/// - key `framelet.pwd.<sourceId>` -> 对应媒体源的密码
/// 密码永不进入代码、日志或 Git 仓库。
class CredentialStore {
  CredentialStore();

  /// macOS 默认使用 data-protection keychain，需要
  /// `keychain-access-groups` entitlement（进而需要 provisioning profile）。
  /// 当前 DMG 为 ad-hoc 签名，取不到该权限会让所有读写抛错；回退到
  /// legacy keychain 即可，无需额外 entitlement。
  final FlutterSecureStorage _storage = Platform.isMacOS
      ? const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        )
      : const FlutterSecureStorage();

  Future<String?> readSources() => _storage.read(key: 'framelet.sources');

  Future<void> writeSources(String json) =>
      _storage.write(key: 'framelet.sources', value: json);

  Future<String?> readPassword(String sourceId) =>
      _storage.read(key: 'framelet.pwd.$sourceId');

  Future<void> writePassword(String sourceId, String password) =>
      _storage.write(key: 'framelet.pwd.$sourceId', value: password);

  Future<void> deletePassword(String sourceId) =>
      _storage.delete(key: 'framelet.pwd.$sourceId');

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> delete(String key) => _storage.delete(key: key);
}
