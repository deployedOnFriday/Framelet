# 拾帧 Framelet

一个面向 Windows 的本地 / WebDAV 媒体库播放器，使用 Flutter 与 media_kit（mpv）构建。

## 功能

- **媒体源**：支持本地目录与 WebDAV，自动递归扫描电影、剧集、动漫，并跳过花絮、隐藏文件和快捷方式。
- **媒体库**：媒体源、扫描结果和播放历史保存在 SQLite（`framelet.db`），WebDAV 密码等敏感信息仍由系统安全存储保管。
- **外挂字幕**：自动发现视频同目录的同名字幕，支持 `.srt`、`.ass`、`.ssa`、`.vtt`、`.sub`；WebDAV 字幕会先下载到临时目录再加载。
- **弹幕**：弹弹play 直连 + 自建服务双源并行搜索，动漫走官方接口，国产剧由自建源补充。
- **刮削**：内置 TMDB 密钥与多条免代理直连线路（含 `api.tmdb.org` 备用域名），海报走 Bunny CDN、IP 直连与加速节点兜底；TMDB 完全不可达时手动匹配自动回退 TVmaze。设置页提供线路检测、日志与缓存清理。未匹配条目会以渐变封面保留在媒体库中，可手动补全。
- **应用内更新**：自动测速 GitHub 直连与国内镜像，并按文件大小启用多线程分段下载，减少安装包下载等待。
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

弹幕默认同时查询两个源，结果合并展示：

- **弹弹play 直连**：内置开放平台凭据，签名直连官方 API v2，动漫覆盖全、通常 1–3 秒返回。
- **自建服务**：内置了一个自建地址（以混淆形式存放，不直接出现在配置文件里），也可以在设置里换成
  LogVar / 御坂 等兼容服务。地址支持 `https://danmu.example.com/<Token>`、
  `http://192.168.1.100:7768/api/v1/<Token>` 等写法，自动拼接 `/api/v2/...`，末尾斜杠可有可无。

双源模式下官方已经搜到结果时，自建源最多再等 3 秒；官方无结果时最多等 30 秒，超时就用
已拿到的结果，不会把播放页卡住。同一个 `episodeId` 的重复条目会自动去重。两个源都可以在
「设置 → 弹幕」里单独关闭。

LogVar、御坂网络弹幕服务都是开源、可自托管的方案（AGPL-3.0），本身不收取费用，但需要自行部署并维护弹幕数据源。

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
