import 'package:flutter/foundation.dart';

/// 全局"数据变更"信号：任何 任务/时间轴块/清单 增删改成功后 bump() 一下，
/// DDL / 清单 / 周视图(时间轴) 各自监听后重拉自己。
///
/// 背景：RootScreen 用 IndexedStack 把三个面板都常驻，切页不 re-init，各面板只在
/// 首次打开时拉一次数据、且只在自己操作后刷新 → 在 DDL 删了任务，清单页还留着旧数据。
/// 有了这个信号,任何一处改动都通知到所有面板，跨面板自动同步。
class PlanBus {
  PlanBus._();
  static final PlanBus instance = PlanBus._();

  /// 每次数据变更 +1；各面板监听此值变化后重新拉取。
  final ValueNotifier<int> revision = ValueNotifier(0);

  void bump() => revision.value++;
}
