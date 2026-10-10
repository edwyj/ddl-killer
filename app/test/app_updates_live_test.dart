import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/app_updates.dart';

void main() {
  test('native update client reads the published manifest', () async {
    final updates = AppUpdates(
      installed: () async => (name: '0.9.3', build: 21),
    );
    try {
      await updates.check();
      expect(updates.error, isNull, reason: updates.diagnostic);
      expect(updates.release!.build, greaterThanOrEqualTo(22));
      expect(updates.available, true);
    } finally {
      updates.dispose();
    }
  }, skip: !const bool.fromEnvironment('LIVE_UPDATE_PROBE'));
}
