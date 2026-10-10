import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

abstract class VoiceRecorder {
  Future<bool> permission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

class DeviceVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _instance;
  AudioRecorder get _recorder => _instance ??= AudioRecorder();
  @override
  Future<bool> permission() => _recorder.hasPermission();
  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ),
  );
  @override
  Future<void> stop() async {
    await _instance?.stop();
  }

  @override
  Future<void> dispose() async {
    await _instance?.dispose();
  }
}

enum VoiceState { idle, preparing, recording, recognizing, failed }

/// Audio stays in memory and is discarded on cancel, background or disposal.
class VoiceInput extends ChangeNotifier with WidgetsBindingObserver {
  VoiceInput({required this.transcribe, VoiceRecorder? recorder})
    : recorder = recorder ?? DeviceVoiceRecorder() {
    WidgetsBinding.instance.addObserver(this);
  }
  final VoiceRecorder recorder;
  final Future<String> Function(Uint8List) transcribe;
  VoiceState state = VoiceState.idle;
  String? error, text;
  int seconds = 0;
  int _epoch = 0;
  bool _disposed = false;
  BytesBuilder? _buffer;
  Uint8List? _pending;
  Timer? _timer;
  StreamSubscription<Uint8List>? _subscription;
  bool get busy =>
      state == VoiceState.preparing || state == VoiceState.recognizing;
  bool get recording => state == VoiceState.recording;
  bool get canRetry => _pending != null && state == VoiceState.failed;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (busy || recording || _disposed) return;
    final epoch = ++_epoch;
    state = VoiceState.preparing;
    error = null;
    text = null;
    _pending = null;
    seconds = 0;
    _notify();
    try {
      if (!await recorder.permission()) {
        throw const VoiceError('麦克风权限未开启，请在设备或浏览器设置中允许后重试');
      }
      if (epoch != _epoch) return;
      final stream = await recorder.start();
      if (epoch != _epoch) {
        await recorder.stop();
        return;
      }
      _buffer = BytesBuilder(copy: false);
      _subscription = stream.listen((chunk) {
        if (epoch != _epoch || _buffer == null) return;
        final remaining = 1920000 - _buffer!.length;
        _buffer!.add(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
        if (_buffer!.length >= 1920000) unawaited(finish());
      }, onError: (_) => unawaited(_recordingFailed()));
      state = VoiceState.recording;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        seconds++;
        _notify();
        if (seconds >= 60) unawaited(finish());
      });
      _notify();
    } catch (e) {
      if (epoch != _epoch) return;
      state = VoiceState.failed;
      error = e is VoiceError ? e.message : '暂时无法录音，请检查麦克风权限或使用文字输入';
      _notify();
    }
  }

  Future<void> _recordingFailed() async {
    await cancel();
    if (_disposed) return;
    state = VoiceState.failed;
    error = '录音中断了，请重新录音';
    _notify();
  }

  Future<void> finish() async {
    if (!recording) return;
    final epoch = _epoch;
    // Keep accepting the recorder's final PCM chunk while stop drains the stream.
    _timer?.cancel();
    final draining = _subscription;
    state = VoiceState.preparing;
    _notify();
    try {
      await recorder.stop();
      await draining?.cancel();
      if (epoch != _epoch) return;
      final pcm = _buffer?.takeBytes();
      _buffer = null;
      if (pcm == null || pcm.length < 16000) {
        throw const VoiceError('录音太短，请再说一次');
      }
      _pending = pcmWav(pcm);
      await retry();
    } catch (e) {
      if (epoch == _epoch && !_disposed) {
        state = VoiceState.failed;
        error = e is VoiceError ? e.message : '录音结束失败，请重新录音';
        _notify();
      }
    }
  }

  Future<void> retry() async {
    if (_pending == null || state == VoiceState.recognizing || _disposed) {
      return;
    }
    final epoch = _epoch;
    state = VoiceState.recognizing;
    error = null;
    _notify();
    try {
      final result = await transcribe(_pending!);
      if (epoch != _epoch) return;
      text = result;
      _pending = null;
      state = VoiceState.idle;
    } catch (e) {
      if (epoch != _epoch) return;
      state = VoiceState.failed;
      error = e is VoiceError ? e.message : '识别失败，录音已临时保留，可以重试';
    }
    _notify();
  }

  Future<void> cancel() async {
    ++_epoch;
    _timer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    try {
      await recorder.stop();
    } catch (_) {}
    _buffer = null;
    _pending = null;
    text = null;
    error = null;
    state = VoiceState.idle;
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission/system dialogs can briefly mark the app inactive.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(cancel());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    unawaited(recorder.dispose());
    _buffer = null;
    _pending = null;
    super.dispose();
  }
}

class VoiceError implements Exception {
  const VoiceError(this.message);
  final String message;
}

Uint8List pcmWav(Uint8List pcm) {
  final result = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(result);
  void label(int start, String value) =>
      result.setRange(start, start + value.length, value.codeUnits);
  label(0, 'RIFF');
  data.setUint32(4, result.length - 8, Endian.little);
  label(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  label(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  result.setRange(44, result.length, pcm);
  return result;
}
