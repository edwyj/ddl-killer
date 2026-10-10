import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/schedule_import_screen.dart';

final class _File extends PlatformFile {
  _File(this.text, {this.reportedSize, this.name = 'schedule.json'});
  final String text;
  final int? reportedSize;
  @override
  final String name;
  @override
  Uri get uri => Uri.parse('file:///schedule.json');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => reportedSize ?? utf8.encode(text).length;
  @override
  Future<int> length() async => lengthSync()!;
  @override
  Future<Uint8List> readAsBytes() async =>
      Uint8List.fromList(utf8.encode(text));
  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList(utf8.encode(text)));
}

void main() {
  testWidgets('schedule hint disappears on focus above a mobile keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(const MaterialApp(home: ScheduleImportScreen()));
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      isNotNull,
    );
    await tester.tap(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '{"courses":[]}');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '{"courses":[]}',
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'file chooser previews BOM JSON and imports only after confirmation',
    (tester) async {
      Map<String, dynamic>? imported;
      await tester.pumpWidget(
        MaterialApp(
          home: ScheduleImportScreen(
            pickFile: () async =>
                _File('\uFEFF{"semester_start":"2026-08-31","classes":[]}'),
            importSchedule: (value) async {
              imported = value;
            },
          ),
        ),
      );
      await tester.tap(find.text('选择课表文件'));
      await tester.pumpAndSettle();
      expect(imported, isNull);
      expect(find.textContaining('已选择：schedule.json'), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(imported!['semester_start'], '2026-08-31');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cancel, invalid JSON and large files preserve pasted content', (
    tester,
  ) async {
    PlatformFile? picked;
    await tester.pumpWidget(
      MaterialApp(home: ScheduleImportScreen(pickFile: () async => picked)),
    );
    await tester.enterText(find.byType(TextField), '{"classes":[]}');
    for (final file in [
      null,
      _File('broken'),
      _File('{"unrelated":"json"}'),
      _File('{}', name: 'wrong.txt'),
      _File('{}', reportedSize: 2 * 1024 * 1024),
    ]) {
      picked = file;
      await tester.tap(find.text('选择课表文件'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '{"classes":[]}',
      );
      expect(tester.takeException(), isNull);
    }
    expect(find.textContaining('超过 1 MB'), findsOneWidget);
  });
  testWidgets(
    'closing the screen while choosing a file causes no late update',
    (tester) async {
      final picker = Completer<PlatformFile?>();
      await tester.pumpWidget(
        MaterialApp(home: ScheduleImportScreen(pickFile: () => picker.future)),
      );
      await tester.tap(find.text('选择课表文件'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      picker.complete(_File('{}'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
