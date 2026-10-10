<p align="center">
  <img src="app/assets/icon/app_icon.png" width="104" alt="DDL Killer 官方 Logo">
</p>

<h1 align="center">DDL Killer</h1>

<p align="center"><strong>让想做的事，拥有自己的时间。</strong></p>
<p align="center">面向中国大学生，把课表、DDL 和个人计划放在一起，让 AI 帮你安排。</p>

<p align="center">
  <a href="LICENSE"><img src="docs/assets/readme/license.svg" alt="许可证：AGPL-3.0-only"></a>
  <img src="docs/assets/readme/platforms.svg" alt="支持 Web 与 Android">
  <img src="docs/assets/readme/free.svg" alt="软件完全免费">
</p>

<p align="center">
  <a href="https://app.ddlkiller.com"><strong>使用网页版</strong></a> ·
  <a href="https://ddlkiller.com/download.html"><strong>下载 Android</strong></a> ·
  <a href="https://ddlkiller.com">官网</a> ·
  <a href="https://ddlkiller.com/help.html">使用帮助</a> ·
  <a href="README.en.md">English</a>
</p>

## 上课之外，给想做的事找到时间

课表在教务系统里，作业记在清单上，考试有自己的截止日期，社团和个人计划又散落在别处。真正安排一天时，我们需要把这些信息放到一起：**哪些时间已经有课，哪些事情快到期，还有什么时间留给自己？**

DDL Killer 从中国大学生的这个日常需求出发。导入课表后，课程和个人安排出现在同一条时间轴上；任务既可以设置 DDL，也可以安排到具体时段。AI 计划助手 **Alice 🎀** 会结合课程、截止日期和已有安排提出方案，由你查看、调整和确认。

<p align="center">
  <a href="docs/assets/readme/week.png"><img src="docs/assets/readme/week.png" width="100%" alt="DDL Killer 周视图：课程、自习、项目和休闲安排在同一周时间轴中"></a>
</p>
<p align="center"><em>一周里的课程、任务和自己的生活，都有位置。</em></p>

## 从“记下来”到“安排好”

| 你想解决的事 | DDL Killer 怎么帮忙 |
| --- | --- |
| 不想来回对照课表和计划 | 导入学期课表，在周视图和每日安排中一起查看课程与个人时间块。 |
| 知道快到期，却没留时间做 | 用清单整理任务和 DDL；“今天”单独提醒当天截止、还没排时间的事。 |
| 事情太多，不知道从哪儿安排 | 告诉 Alice 任务与偏好，生成新任务或排期草案，结合课表检查，再由你确认应用。 |
| 已经有习惯使用的模型或智能体 | 配置自己的 API Key，或通过 MCP 接入自己的智能体。 |
| 需要电脑和手机一起用 | Web 与 Android 同步；启用设备离线数据后，可查看和编辑已缓存内容，联网后同步。 |

<p align="center">
  <a href="docs/assets/readme/today.png"><img src="docs/assets/readme/today.png" width="31%" alt="今天：课程与个人安排按时间排列，下方单独提醒今天截止的任务"></a>
  <a href="docs/assets/readme/deadlines.png"><img src="docs/assets/readme/deadlines.png" width="31%" alt="DDL：月历与所选日期的截止任务，支持查看已完成事项"></a>
  <a href="docs/assets/readme/alice.png"><img src="docs/assets/readme/alice.png" width="31%" alt="Alice：先预览 AI 提出的实验报告与复习安排，再确认应用"></a>
</p>
<p align="center"><strong>今天的安排 · 截止日期 · Alice 计划助手</strong><br><sub>以上展示图由真实界面组件渲染，全部使用虚构演示数据；AI 对话为演示内容。点击图片查看大图。</sub></p>

AI 建议仅供参考，应用前请核对。离线支持针对已缓存的业务数据；首次登录、AI、邮件与云端功能需要联网。

## 把你的课表带进来

目前提供 **山东大学、哈尔滨工业大学（深圳）** 的课表导出脚本与[使用教程](https://ddlkiller.com/kebiao-help.html)。适用范围取决于校区、教务系统和学期，使用前请核对；具体限制见[学校适配说明](docs/school-timetable-export.md#当前有哪些实现可参考)。

你的学校还没有适配？欢迎有能力的同学，**按照学校规定，从本人有权访问的数据中开发导出适配**，将课表转换为统一 JSON，复用现有导入、日历和 AI 避课流程。

我们为此准备了[课表导出脚本开发教程](docs/school-timetable-export.md)、[完整虚构课表示例](docs/examples/timetable-demo.json)和[离线校验工具](docs/examples/validate-timetable-demo.mjs)。教程从数据来源、学期与周次、节次映射讲到解析测试和贡献要求。可以先支持一所学校的一个校区，说明范围，再逐步完善。提交时请使用虚构样本，不附教务账号、Cookie 或个人课表。

## 也欢迎你，用它做自己的项目

DDL Killer 希望成为一个可以继续生长的起点。欢迎复用现有框架与功能，做自己的计划工具、探索 AI 安排方式，或改善本校同学查看课表和安排时间的体验。

可以从三个方向开始：

- **增加一所学校的适配**：转换课表数据，复用已有客户端，不必从头写日历。
- **改善本校课表体验**：调整课程详情、周视图或空闲时间展示，让它更贴近本校的使用习惯。
- **做自己的计划与 AI 工具**：参考任务排期、离线同步、空闲时段计算、草案校验与确认流程。

[开发与复用指南](docs/developer-guide.md)提供架构图、源码入口、数据关系和这三条路线。仓库目前是一套完整应用，尚未封装成独立 SDK；抽取模块时，需要同时处理其数据、认证和同步依赖。复用时请遵守下方许可证，并清楚标识自己的版本与维护身份。

## 使用、开发与贡献入口

| 你现在想做什么 | 入口 |
| --- | --- |
| 直接开始使用 | [网页版](https://app.ddlkiller.com) · [Android 下载页](https://ddlkiller.com/download.html) · [使用帮助](https://ddlkiller.com/help.html) |
| 使用自己的模型 | [API Key 获取与配置教程](https://ddlkiller.com/api-key-help.html)；MCP 在应用设置中连接 |
| 读懂代码、二次开发 | [开发与复用指南](docs/developer-guide.md) |
| 为自己的学校导出课表 | [课表导出脚本开发教程](docs/school-timetable-export.md) |
| 跑起自己的实例 | [自部署说明](docs/self-hosting.md)，含首次账号、构建、邮件、AI 与 MCP 配置 |
| 提交改进或排查问题 | [贡献说明](CONTRIBUTING.md) · [测试与 CI](docs/ci.md) · [安全反馈](SECURITY.md) |

后端使用 **Node.js 24 + SQLite**，客户端使用 **Flutter / Dart**，MCP 网关位于 `mcp-server/`，官网与帮助页位于 `website/`。完整目录和源码入口见开发指南。依赖版本以项目约束和 lockfile 为准。

正式版与 Beta 的数据相互独立，普通使用建议选择正式版。开发请使用自己的测试环境和虚构数据。

## 软件免费，AI 体验额度有边界

**DDL Killer 不收取任何软件使用费用。**

官方 AI 免费额度用于让新用户体验助手，判断它是否适合自己。这些 AI 调用会增加我们的运营成本；额度可能根据成本与运行情况调整。长期使用建议配置自己的 API Key，或通过 MCP 接入自己的智能体。第三方模型或智能体服务的费用按对应服务商规则由你承担。

任何以 DDL Killer 官方名义收取软件使用费用的行为均非官方，请勿付款。第三方基于开源代码提供的服务应明确自己的身份；第三方服务的定价不代表官方收费。

## 许可证与品牌

Copyright (c) 2026 Andy233.

项目原创代码采用 [GNU Affero General Public License v3.0](LICENSE)，SPDX 标识为 **`AGPL-3.0-only`**。复用、修改、分发或通过网络提供修改版时，请遵守许可证对对应源码等事项的要求；许可证允许商业使用。

第三方依赖与字体保留各自许可证，见[第三方说明](THIRD_PARTY_NOTICES.md)。项目名称与 Logo 的使用不能让人误以为第三方版本或服务由官方提供或背书。
