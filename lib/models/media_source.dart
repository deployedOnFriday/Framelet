class MediaSource {
  const MediaSource({
    required this.name,
    required this.address,
    required this.username,
    this.directory = '/',
    this.connected = true,
    this.lastSync = '尚未同步',
  });

  final String name;
  final String address;
  final String username;
  final String directory;
  final bool connected;
  final String lastSync;

  MediaSource copyWith({bool? connected, String? lastSync}) {
    return MediaSource(
      name: name,
      address: address,
      username: username,
      directory: directory,
      connected: connected ?? this.connected,
      lastSync: lastSync ?? this.lastSync,
    );
  }
}
