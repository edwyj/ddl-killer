# DDL Killer 客户端

本目录是 DDL Killer 的 Flutter Web / Android 客户端。

- 项目介绍和在线使用入口：[根目录 README](../README.md)
- 本地启动与 Web / APK 构建：[自部署说明](../docs/self-hosting.md)
- 开发与贡献：[CONTRIBUTING.md](../CONTRIBUTING.md)
- 自动化检查：[CI 说明](../docs/ci.md)

SDK 需要满足 `pubspec.yaml` 中的 Dart 版本约束。安装对应 Flutter SDK 后，在本目录执行：

```sh
flutter pub get
flutter test
```

Web 默认使用页面同源 API；Android 默认连接官方服务，自部署构建时须设置 `API_BASE`。具体命令和已知官方 URL 耦合见自部署说明。
