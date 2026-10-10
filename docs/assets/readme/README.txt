DDL Killer README 展示图

today.png       1170 x 2532   今天：课程、个人安排、今日截止提醒
week.png        3600 x 2580   一周：课程与个人任务放在同一时间轴
deadlines.png   1170 x 2532   DDL：月历与截止任务
alice.png       1170 x 2532   Alice：待确认的 AI 排期方案

页面布局仍为手机 390 x 844 / 电脑 1200 x 860 逻辑像素。
通过 RepaintBoundary.toImage(pixelRatio: 3) 直接渲染高清 PNG，
不放大已有图片；README 的展示宽度与比例保持不变。
启用实际阴影，避免 Flutter 截图测试默认将阴影替换为黑色调试轮廓。

这些 PNG 由本仓库实际 Flutter 界面组件渲染，采用内置“薰衣草”主题。
课程、安排、截止事项和 AI 回答全部为专门编写的虚构演示数据。
它们不是用户真实安排、不是生产数据、不是线上模型能力评测结果。
不包含真实学生、教师、教室、个人账号或其他身份信息。
图片没有裁剪、拼贴、重绘或后期修改；README 排列不属于产品界面。
业务页面使用实际组件；导航宿主按 RootScreen 当前样式复现，隐藏滚动条；
这些展示图不等同整机截图。Alice 使用实际面板组件在独立宿主中渲染。

复现（已安装项目要求的 Flutter SDK，并在 app/ 完成 flutter pub get）：
  powershell -NoProfile -File docs/assets/readme/render-previews.ps1

render_previews.dart 仅用于文档素材，不进入业务测试门禁。
脚本将它临时复制到 app/test/，运行 Flutter golden 渲染，然后删除临时文件。
所有 HTTP 请求都由内存 MockClient 响应，AI 由演示仓储响应，不连接生产服务。
今天、DDL、AI 演示日期固定为 2026-10-08。
周视图使用实际 WeekScreen，日期导航与“今天”高亮随执行时的当前周变化；
课程与任务均按星期位置生成，内容不随日期改变。

来源：
  app/lib/screens/list_screen.dart
  app/lib/screens/week_screen.dart
  app/lib/screens/ddl_screen.dart
  app/lib/screens/ai_planner_sheet.dart
  app/lib/theme.dart
