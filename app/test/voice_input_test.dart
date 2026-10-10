import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/voice_input.dart';

class FakeRecorder implements VoiceRecorder {
  final stream = StreamController<Uint8List>();
  bool allowed = true;
  int stopped = 0;
  @override
  Future<bool> permission() async => allowed;
  @override
  Future<Stream<Uint8List>> start() async => stream.stream;
  @override
  Future<void> stop() async => stopped++;
  @override
  Future<void> dispose() => stream.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('permission rejection never uploads or starts recording', () async {
    var uploads = 0;
    final recorder = FakeRecorder()..allowed = false;
    final voice = VoiceInput(
      recorder: recorder,
      transcribe: (_) async {
        uploads++;
        return 'text';
      },
    );
    await voice.start();
    expect(voice.state, VoiceState.failed);
    expect(uploads, 0);
    voice.dispose();
  });
  test(
    'failure keeps audio only for explicit retry; cancel clears it',
    () async {
      var uploads = 0;
      final recorder = FakeRecorder();
      final voice = VoiceInput(
        recorder: recorder,
        transcribe: (wav) async {
          expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 16000);
          uploads++;
          if (uploads == 1) throw const VoiceError('网络失败');
          return '明天写报告';
        },
      );
      await voice.start();
      recorder.stream.add(Uint8List(32000));
      await Future<void>.delayed(Duration.zero);
      await voice.finish();
      expect(voice.canRetry, true);
      expect(uploads, 1);
      await voice.retry();
      expect(voice.text, '明天写报告');
      expect(uploads, 2);
      await voice.cancel();
      expect(voice.canRetry, false);
      expect(voice.text, isNull);
      voice.dispose();
    },
  );
  test('background stops microphone and late response cannot restore discarded text', () async {
    final pending = Completer<String>();
    final recorder = FakeRecorder();
    final voice = VoiceInput(
      recorder: recorder,
      transcribe: (_) => pending.future,
    );
    await voice.start();
    recorder.stream.add(Uint8List(32000));
    await Future<void>.delayed(Duration.zero);
    final finishing = voice.finish();
    await Future<void>.delayed(Duration.zero);
    voice.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    pending.complete('old account text');
    await finishing;
    expect(voice.text, isNull);
    expect(voice.state, VoiceState.idle);
    expect(recorder.stopped, greaterThan(0));
    voice.dispose();
  });
}
