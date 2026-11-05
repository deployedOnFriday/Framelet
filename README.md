# 拾帧 Framelet

一个面向 Windows 的本地 / WebDAV 媒体库播放器，使用 Flutter 与 media_kit（mpv）构建。

## 功能

- **媒体源**：支持本地目录与 WebDAV，自动递归扫描电影、剧集、动漫，并跳过花絮、隐藏文件和快捷方式。
- **媒体库**：媒体源、扫描结果和播放历史保存在 SQLite（`framelet.db`），WebDAV 密码等敏感信息仍由系统安全存储保管。
- **外挂字幕**：自动发现视频同目录的同名字幕，支持 `.srt`、`.ass`、`.ssa`、`.vtt`、`.sub`；WebDAV 字幕会先下载到临时目录再加载。
- **弹幕**：支持 DanDanPlay 官方 API，以及兼容 DanDanPlay 协议的自托管服务（如御坂网络弹幕服务）。
- **刮削**：内置 TMDB 密钥与多条免代理直连线路，也可配置代理；设置页提供线路检测、日志与缓存清理。未匹配条目会以渐变封面保留在媒体库中，可手动补全。
- **播放**：播放进度记忆、内嵌 / 外挂字幕切换、弹幕开关、倍速与常用播放控制。

## 字幕命名

把字幕放在视频同目录，文件名与视频保持一致即可自动加载：

```text
Movie.mkv
Movie.srt
Movie.zh.srt
Movie_en.ass
```

也可以在播放器中通过「加载外挂字幕…」手动选择文件。

## 弹幕服务

在「设置 → 弹幕」中选择服务：

- **DanDanPlay**：在 [开发者中心](https://doc.dandanplay.com/open/) 申请 AppId / AppSecret。非商业项目可使用标准免费配额；商业用途需要获得授权。凭据仅保存在本机。
- **御坂 / 自定义**：填写兼容 DanDanPlay API 的完整地址，例如 `http://192.168.1.100:7768/api/v1/<Token>`。御坂网络弹幕服务是开源、可自托管的方案（AGPL-3.0），本身不收取费用，但需要自行部署服务并维护弹幕数据源。

弹幕服务只提供滚动弹幕，不提供 `.srt` / `.ass` 字幕文件。

## 开发

项目自带 Flutter 工具链（`.toolchain/flutter`），在仓库根目录执行：

```powershell
.\.toolchain\flutter\bin\flutter.bat pub get
.\.toolchain\flutter\bin\flutter.bat analyze
.\.toolchain\flutter\bin\flutter.bat test
.\.toolchain\flutter\bin\flutter.bat build windows --release
```

构建产物位于 `build\windows\x64\runner\Release\`。

## 数据位置

- 媒体库数据库：应用支持目录下的 `framelet.db`（由 `path_provider` 决定，Windows 通常位于 `%APPDATA%` 下的应用目录）。
- 旧版本保存在 `flutter_secure_storage` 中的媒体源、扫描缓存和历史会在首次启动时自动迁移，迁移成功后删除旧副本。
