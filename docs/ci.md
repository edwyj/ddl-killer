# 持续集成

工作流在 [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)。修改 `app/`、`backend/` 或该工作流的 main 推送、面向 main 的 Pull Request 会运行，也可从 GitHub Actions 手动运行。同一分支或 PR 的旧任务会被取消。

## 运行环境

- Ubuntu 24.04，Node.js 24，与后端 Dockerfile 的运行时主版本一致。
- Flutter **3.47.2 / Dart 3.13.2**，对应官方 `flutter/flutter` 提交 `d3b14c876900e553bc736ca19295fc09e3853e8e`。该提交与应用 `.metadata`、项目现有开发 SDK 相符。
- GitHub 官方 `actions/checkout`、`actions/setup-node`、`actions/cache` 固定到完整提交 SHA；Flutter 从官方仓库浅取对应版本标签、检出固定提交，并在恢复缓存后再次检查 HEAD。保留版本标签供 Flutter 正确识别 SDK 版本。
- npm 和 pub 缓存按锁文件匹配；安装分别使用 `npm ci` 与 `flutter pub get --enforce-lockfile`。依赖安装不升级锁文件。

## 检查范围

后端运行完整 `npm test`，使用已有的内存/临时 SQLite、合成账号和替身服务，覆盖身份验证、邮箱队列、账户隔离、离线重放、MCP/OAuth、AI 草案验证、确认与撤销等行为。

Flutter 运行 `flutter analyze --no-pub --no-fatal-infos lib test`。分析错误和 warning 会导致失败；既有的 5 个 info 暂不作为失败条件（3 个花括号建议、2 个多余 import）。后续清理时可重新启用 info 门禁。

Flutter 行为测试显式列在工作流中，覆盖：

- AI 会话、历史恢复、草案确认、任务要求、部分应用与撤销、键盘发送、配置及敏感内容缓存边界。
- 网络错误、凭据存储、离线快照与真实本地 API 的离线重放、课表导入、任务完成和顺延、日历拖动与重叠。
- 更新检查、登录下载入口、MCP 连接与 OAuth 授权。
- 另以 `RELEASE_CHANNEL=beta` 运行 Beta 更新及两处下载入口测试，确保渠道边界实际执行。

Linux CI 不运行现有 Windows 截图基线测试，避免跨平台字体渲染差异。视觉回归仍应在生成基线的环境运行并人工审阅；新增关键行为测试应加入工作流列表。CI 不开启 `LIVE_UPDATE_PROBE`，不读取 `.env`、生产数据库或 GitHub Secrets，不调用在线模型、邮件服务或部署脚本，也不构建签名 APK。

## 本地复现

安装上述版本后，在 `backend/` 执行：

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

在 `app/` 执行：

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub --no-fatal-infos lib test
```

然后复制工作流 `Run core Flutter tests` 中的完整命令。离线测试会通过 Node 启动 `backend/tools/offline-fixture.js`，因此本地也需要先安装 backend 依赖。

Beta 边界测试：

```sh
flutter test --no-pub --concurrency=2 --timeout=2m \
  --dart-define=RELEASE_CHANNEL=beta \
  test/beta_update_channel_test.dart \
  test/about_download_channel_test.dart \
  test/login_download_test.dart
```

PowerShell 可把命令写在一行，或用反引号代替上述 shell 的换行反斜杠。

## 维护与权限

工作流只授予 `contents: read`，checkout 不保留凭据；不使用 `pull_request_target`，也没有发布步骤。来自 fork 的 PR 不需要维护者提供任何凭据。修改依赖时同时提交相应锁文件；更新 SDK 时一并核对 Flutter 版本、固定提交、缓存目录及测试结果。

2026-10-10 在现有 Windows 开发环境完成初始验证：后端 241 项、Flutter 核心 140 项、Beta 边界 6 项全部通过；锁文件安装与静态分析通过，分析仍有上述 5 个 info。锁文件未变。

Actions 的实际运行结果需在推送后从 GitHub 查看。本地命令通过只能验证检查本身，不能证明托管 runner 已成功运行。

参考：[GitHub checkout](https://github.com/actions/checkout)、[setup-node](https://github.com/actions/setup-node)、[cache](https://github.com/actions/cache)、[Flutter 官方 3.47.2 标签](https://github.com/flutter/flutter/tree/3.47.2)、[Flutter SDK 档案](https://docs.flutter.dev/install/archive)。
