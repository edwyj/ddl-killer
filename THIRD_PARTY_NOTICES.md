# 第三方组件与许可证

DDL Killer 原创代码采用 `AGPL-3.0-only`。第三方组件保留各自的版权与许可证，项目许可证不替代这些许可。

## 随客户端分发的字体

| 文件 | 许可证正文 |
| --- | --- |
| `app/assets/fonts/NotoSansSC.ttf` | [SIL Open Font License 1.1](app/assets/fonts/NotoSansSC-LICENSE.txt) |
| `app/assets/fonts/NotoColorEmoji.ttf` | [SIL Open Font License 1.1](app/assets/fonts/NotoColorEmoji-LICENSE.txt) |

字体许可证作为 Flutter assets 一同打包。修改或重新分发字体时须保留对应许可证，遵守其保留字体名等要求。

## 软件依赖

- Flutter/Dart 依赖与解析版本：`app/pubspec.yaml`、`app/pubspec.lock`。
- 后端依赖与解析版本：`backend/package.json`、`backend/package-lock.json`。
- MCP 依赖与解析版本：`mcp-server/package.json`、`mcp-server/package-lock.json`。
- 邀请机器人依赖：`invite-bot/` 中的依赖清单。

发布或重新分发时，应保留相应依赖包内的 LICENSE、NOTICE 和版权说明；保留 Flutter 构建生成的第三方许可材料（例如 `NOTICES`）；增加许可页面入口时，应展示相应信息。本文件列出当前归档位置，不替代对具体发布产物全部第三方依赖的许可证核查。
