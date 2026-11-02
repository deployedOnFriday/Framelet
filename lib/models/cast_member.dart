/// 演职员条目（纯 Dart，刮削服务与 UI 共用）。
class CastMember {
  const CastMember({required this.name, required this.role, this.photoUrl});

  final String name;
  final String role;
  final String? photoUrl;

  Map<String, Object?> toJson() => {
    'name': name,
    'role': role,
    'photoUrl': photoUrl,
  };

  factory CastMember.fromJson(Map<String, Object?> json) => CastMember(
    name: json['name']! as String,
    role: json['role'] as String? ?? '',
    photoUrl: json['photoUrl'] as String?,
  );
}
