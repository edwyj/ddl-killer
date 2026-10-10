import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../voice_input.dart';
import '../models/ai_planner.dart';
import '../widgets/ai_draft_preview.dart';
import '../widgets/ai_requirements_editor.dart';
import '../ai_assistant_state.dart';
import '../ai_display_text.dart';
import '../ai_usage_policy.dart';
import 'ai_invite_screen.dart';

const _betaCopy = aiUsagePolicyCopy;

abstract class AiPlannerRepository {
  Future<AiTurnResult> createSession(
    String message,
    DateTime start,
    DateTime end,
  );
  Future<AiTurnResult> addTurn(String sessionId, String message);
  Future<List<AiSessionSummary>> listSessions();
  Future<AiSessionDetail> getSession(String sessionId);
  Future<void> closeSession(String sessionId);
  Future<void> deleteSession(String sessionId);
  Future<void> applyDraft(String draftId);
}

abstract class AdvancedAiPlannerRepository {
  Future<Map<String, dynamic>> getOptions();
  Future<AiTurnResult> generateConfigured(
    String message, {
    String? sessionId,
    required DateTime start,
    required DateTime end,
    required Map<String, dynamic> configuration,
  });
  Future<AiApplyResult> applySelected(
    String draftId,
    List<String> ids,
    List<String> confirmedRequirementIds,
  );
  Future<void> undoApplication(String id);
}

class ApiAiPlannerRepository
    implements AiPlannerRepository, AdvancedAiPlannerRepository {
  const ApiAiPlannerRepository();

  @override
  Future<AiTurnResult> createSession(
    String message,
    DateTime start,
    DateTime end,
  ) => Api.instance.createAiSession(message: message, start: start, end: end);
  @override
  Future<AiTurnResult> addTurn(String sessionId, String message) =>
      Api.instance.addAiTurn(sessionId, message);
  @override
  Future<List<AiSessionSummary>> listSessions() =>
      Api.instance.listAiSessions();
  @override
  Future<AiSessionDetail> getSession(String sessionId) =>
      Api.instance.getAiSession(sessionId);
  @override
  Future<void> closeSession(String sessionId) =>
      Api.instance.closeAiSession(sessionId);
  @override
  Future<void> deleteSession(String sessionId) =>
      Api.instance.deleteAiSession(sessionId);
  @override
  Future<void> applyDraft(String draftId) => Api.instance.applyAiDraft(draftId);
  @override
  Future<Map<String, dynamic>> getOptions() => Api.instance.aiPlanningOptions();
  @override
  Future<AiTurnResult> generateConfigured(
    String message, {
    String? sessionId,
    required DateTime start,
    required DateTime end,
    required Map<String, dynamic> configuration,
  }) => sessionId == null
      ? Api.instance.createAiSession(
          message: message,
          start: start,
          end: end,
          configuration: configuration,
        )
      : Api.instance.addAiTurn(
          sessionId,
          message,
          configuration: configuration,
        );
  @override
  Future<AiApplyResult> applySelected(
    String draftId,
    List<String> ids,
    List<String> confirmedRequirementIds,
  ) => Api.instance.applySelectedAiDraft(draftId, ids, confirmedRequirementIds);
  @override
  Future<void> undoApplication(String id) => Api.instance.undoAiApplication(id);
}

Future<void> showAiPlannerSheet(
  BuildContext context, {
  AiPlannerRepository repository = const ApiAiPlannerRepository(),
}) async {
  final preferences = await SharedPreferences.getInstance();
  if (!context.mounted) return;
  final showIntro = !(preferences.getBool('ai_planner_intro_seen_v1') ?? false);
  if (MediaQuery.sizeOf(context).width < 600) {
    final drag = DraggableScrollableController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (context) => AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: DraggableScrollableSheet(
            controller: drag,
            expand: false,
            initialChildSize: .72,
            minChildSize: .5,
            maxChildSize: .96,
            builder: (context, scroll) => Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    if (drag.isAttached) {
                      drag.jumpTo(
                        (drag.size -
                                details.delta.dy /
                                    (MediaQuery.sizeOf(context).height -
                                        MediaQuery.viewInsetsOf(context)
                                            .bottom))
                            .clamp(.5, .96),
                      );
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 70,
                    ),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: AiPlannerSheet(
                    repository: repository,
                    showIntro: showIntro,
                    scrollController: scroll,
                    onExpand: () {
                      if (drag.isAttached) {
                        unawaited(
                          drag.animateTo(
                            .96,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          ),
                        );
                      }
                    },
                    onIntroSeen: () =>
                        preferences.setBool('ai_planner_intro_seen_v1', true),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      drag.dispose();
    }
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: SizedBox(
          width: 680,
          child: AiPlannerSheet(
            repository: repository,
            showIntro: showIntro,
            onIntroSeen: () =>
                preferences.setBool('ai_planner_intro_seen_v1', true),
          ),
        ),
      ),
    ),
  );
}

class AiPlannerSheet extends StatefulWidget {
  const AiPlannerSheet({
    super.key,
    this.repository = const ApiAiPlannerRepository(),
    this.showIntro = false,
    this.onIntroSeen,
    this.onApplied,
    this.scrollController,
    this.voiceInput,
    this.onExpand,
  });

  final AiPlannerRepository repository;
  final bool showIntro;
  final Future<void> Function()? onIntroSeen;
  final VoidCallback? onApplied;
  final ScrollController? scrollController;
  final VoiceInput? voiceInput;
  final VoidCallback? onExpand;

  @override
  State<AiPlannerSheet> createState() => _AiPlannerSheetState();
}

class _AiPlannerSheetState extends State<AiPlannerSheet> {
  final _input = TextEditingController();
  final _previewKey = GlobalKey();
  late final ScrollController _scroll =
      widget.scrollController ?? ScrollController();
  late final VoiceInput _voice;
  String _voicePrefix = '';
  String? _lastVoiceText;
  void _voiceChanged() {
    if (!mounted) return;
    if (_voice.text != null && _voice.text != _lastVoiceText) {
      _lastVoiceText = _voice.text;
      _input.text = [
        _voicePrefix.trim(),
        _voice.text!,
      ].where((t) => t.isNotEmpty).join(' ');
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
    setState(() {});
  }

  Future<void> _startVoice() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (!(preferences.getBool('asr_consent_v1') ?? false)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('使用语音输入'),
          content: const Text(
            '录音会发送至硅基流动进行识别。DDL Killer 不永久保存录音；识别后的文字可修改，点击发送后才交给 AI 安排。单次最多一分钟。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不使用'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始录音'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await preferences.setBool('asr_consent_v1', true);
    }
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _voicePrefix = _input.text;
    _lastVoiceText = null;
    await _voice.start();
  }

  late bool _showIntro = widget.showIntro;
  bool _loading = false;
  String? _error;
  bool _showPreviousResult = false;
  int _retrySeconds = 0;
  Timer? _retryTimer;
  AiTurnResult? _result;
  bool _closed = false;
  bool _showHistory = false;
  bool _historyLoading = false;
  bool _canContinue = true;
  List<AiSessionSummary> _history = const [];
  Set<String> _selected = {};
  List<AiApplication> _applications = [];
  final List<({bool user, String text})> _transcript = [];
  Map<String, dynamic> _configuration = {};
  bool _requirementsChanged = false;
  bool _showInfo = false;

  @override
  void initState() {
    super.initState();
    _voice =
        widget.voiceInput ??
        VoiceInput(
          transcribe: (bytes) async {
            try {
              return await Api.instance.transcribeVoice(bytes);
            } on ApiException catch (e) {
              throw VoiceError(e.message);
            }
          },
        );
    _voice.addListener(_voiceChanged);
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    final result = _result;
    if (!_closed && result != null) {
      unawaited(
        widget.repository.closeSession(result.sessionId).catchError((_) {}),
      );
    }
    _voice.removeListener(_voiceChanged);
    if (widget.voiceInput == null) {
      _voice.dispose();
    } else {
      unawaited(_voice.cancel());
    }
    _input.clear();
    _input.dispose();
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  Future<void> _continueFromIntro() async {
    await widget.onIntroSeen?.call();
    if (mounted) setState(() => _showIntro = false);
  }

  Future<void> _submit() async {
    if (_loading || _retrySeconds > 0) return;
    final message = _input.text.trim();
    if (message.isEmpty) {
      setState(() => _error = '请先描述你想安排的事情');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final current = _result;
      final advanced = widget.repository;
      final newSession = current == null || !_canContinue;
      final result = advanced is AdvancedAiPlannerRepository
          ? await (advanced as AdvancedAiPlannerRepository).generateConfigured(
              message,
              sessionId: newSession ? null : current.sessionId,
              start: DateTime.now(),
              end: DateTime.now().add(const Duration(days: 13)),
              configuration: _configuration,
            )
          : newSession
          ? await widget.repository.createSession(
              message,
              DateTime.now(),
              DateTime.now().add(const Duration(days: 13)),
            )
          : await widget.repository.addTurn(current.sessionId, message);
      if (!mounted) return;
      _input.clear();
      setState(() {
        if (newSession) {
          _transcript.clear();
          _applications = [];
        } else {
          _transcript.add((user: false, text: current.summary));
        }
        _transcript.add((user: true, text: message));
        _result = result;
        _selected = result.draft.changes
            .map((c) => c.id)
            .whereType<String>()
            .toSet();
        _configuration = {};
        _requirementsChanged = false;
        _canContinue = true;
        _showPreviousResult = false;
      });
      unawaited(_loadHistory());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _previewKey.currentContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              _previewKey.currentContext!,
              duration: const Duration(milliseconds: 180),
            ),
          );
        }
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      final retry = error.details?['retryAfterSeconds'];
      final seconds = retry is num && retry.isFinite
          ? retry.toInt().clamp(1, 3600)
          : error.code == 'AI_RETRY_LATER'
          ? 30
          : 0;
      if (seconds > 0) {
        _retryTimer?.cancel();
        _retrySeconds = seconds;
        _retryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          setState(
            () => _retrySeconds = (seconds - timer.tick).clamp(0, seconds),
          );
          if (_retrySeconds == 0) timer.cancel();
        });
      }
      setState(() {
        _showPreviousResult = _result != null;
        _error = seconds > 0
            ? null
            : error.code == 'AI_QUOTA_EXHAUSTED'
            ? '今日免费额度已用完，你仍可以查看和应用已有草案，或在设置中使用自己的 Key。'
            : aiErrorText(error.code, error.message);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _showPreviousResult = _result != null;
          _error = '暂时没能收到回复，你输入的内容已保留。请检查网络后再试。';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    if (!desktop ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    // Enter belongs to the input method while it is confirming a candidate.
    final value = _input.value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent ||
        _loading ||
        _voice.recording ||
        _voice.busy) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed || keyboard.isControlPressed) {
      final selection = value.selection;
      final start = selection.isValid ? selection.start : value.text.length;
      final end = selection.isValid ? selection.end : start;
      _input.value = TextEditingValue(
        text: value.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
    } else if (!keyboard.isAltPressed && !keyboard.isMetaPressed) {
      if (_retrySeconds == 0 && !_showHistory && value.text.trim().isNotEmpty) {
        unawaited(_submit());
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _close() async {
    await _voice.cancel();
    final sessionId = _result?.sessionId;
    if (sessionId != null) {
      unawaited(widget.repository.closeSession(sessionId).catchError((_) {}));
    }
    _closed = true;
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _apply() async {
    final result = _result!;
    final advanced = widget.repository is AdvancedAiPlannerRepository;
    final ids = _selected.toList();
    if (advanced && ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认应用这份安排？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将应用 ${advanced ? ids.length : result.draft.changes.length} 项安排。你可以稍后撤销；相关内容被修改后，撤销会停止。',
              ),
              if (result.requirements.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text('同时确认这些本次要求：'),
                for (final r in result.requirements)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(r.label),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('再看看'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认应用'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (advanced) {
        final applied = await (widget.repository as AdvancedAiPlannerRepository)
            .applySelected(
              result.draft.id,
              ids,
              result.requirements.map((r) => r.id).toList(),
            );
        if (!mounted) return;
        setState(() {
          _applications.insert(
            0,
            AiApplication(
              id: applied.applicationId,
              applied: applied.applied,
              draftId: result.draft.id,
            ),
          );
          _result = result.withDraft(
            applied.remainingDraft ??
                AiDraft(
                  id: result.draft.id,
                  status: 'applied',
                  changes: result.draft.changes,
                  warnings: const [],
                ),
            summary: applied.remainingDraft != null
                ? '已应用 ${applied.applied} 项，下面是剩余安排。'
                : '已应用 ${applied.applied} 项安排。',
            confirmed: true,
          );
          _selected = _result!.draft.changes
              .map((c) => c.id)
              .whereType<String>()
              .toSet();
          _canContinue = applied.remainingDraft != null;
        });
        widget.onApplied?.call();
        unawaited(_loadHistory());
      } else {
        await widget.repository.applyDraft(result.draft.id);
        _closed = true;
        widget.onApplied?.call();
        if (mounted) Navigator.of(context).maybePop();
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _error = aiErrorText(error.code, error.message));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法确认应用结果，方案已保留。请重试或从历史记录核对。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadHistory() async {
    if (_historyLoading) return;
    if (mounted) setState(() => _historyLoading = true);
    try {
      final history = await widget.repository.listSessions();
      if (mounted) setState(() => _history = history);
    } catch (_) {
      // 历史加载失败不影响当前对话。
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _restoreSession(AiSessionSummary summary) async {
    setState(() {
      _historyLoading = true;
      _error = null;
    });
    try {
      final detail = await widget.repository.getSession(summary.id);
      final turn = detail.turns.isEmpty ? null : detail.turns.last;
      final draft = detail.currentDraft ?? turn?.draft;
      if (turn == null || draft == null) throw StateError('empty history');
      final quota =
          aiAssistantState.settings?.quota ??
          AiQuota(
            limit: 3,
            used: 0,
            reserved: 0,
            remaining: 0,
            resetsAt: DateTime.now(),
            hostedEnabled: true,
            copy: _betaCopy,
          );
      if (!mounted) return;
      setState(() {
        _result = AiTurnResult(
          sessionId: detail.id,
          draft: draft,
          summary: draft.id != turn.draft?.id
              ? '下面是尚未应用的剩余安排。'
              : detail.applications.any(
                  (a) => a.draftId == draft.id && a.status == 'undone',
                )
              ? '这次应用已撤销。'
              : aiSafeText(turn.summary),
          questions: turn.questions.map((item) => aiSafeText(item)).toList(),
          warnings: turn.warnings.map((item) => aiSafeText(item)).toList(),
          quota: quota,
          requirements: detail.requirements,
          exceptions: detail.exceptions,
          exceptionsRevision: detail.exceptionsRevision,
          exceptionsStale: detail.exceptionsStale,
        );
        _selected = draft.changes.map((c) => c.id).whereType<String>().toSet();
        _applications = List.of(detail.applications);
        _configuration = {};
        _requirementsChanged = false;
        _transcript.clear();
        for (final entry in detail.turns) {
          _transcript.add((user: true, text: entry.input));
          if (entry != detail.turns.last) {
            _transcript.add((user: false, text: entry.summary));
          }
        }
        _canContinue =
            (detail.status == AiSessionStatus.active ||
                detail.status == AiSessionStatus.closed) &&
            detail.expiresAt.isAfter(DateTime.now());
        _showPreviousResult = false;
        _showHistory = false;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '这条历史记录暂时无法打开，请稍后重试');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _deleteHistory(AiSessionSummary summary) async {
    try {
      await widget.repository.deleteSession(summary.id);
      if (_result?.sessionId == summary.id && mounted) {
        setState(() {
          _result = null;
          _applications = [];
          _transcript.clear();
          _configuration = {};
          _requirementsChanged = false;
        });
      }
      await _loadHistory();
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请检查网络后重试');
    }
  }

  Future<void> _editRequirements() async {
    final repo = widget.repository;
    if (repo is! AdvancedAiPlannerRepository) return;
    setState(() => _loading = true);
    try {
      final options = await (repo as AdvancedAiPlannerRepository).getOptions();
      if (!mounted) return;
      setState(() => _loading = false);
      final pending = _configuration['manualRequirements'] as List?;
      final requirements = pending == null
          ? _result?.requirements ?? const <AiRequirement>[]
          : pending
                .map(
                  (r) => AiRequirement.fromJson({
                    ...Map<String, dynamic>.from(r as Map),
                    'id': 'pending',
                    'source': '在本次要求中设置',
                    'confirmed': true,
                  }),
                )
                .toList();
      final exceptions = _configuration.containsKey('exceptions')
          ? (_configuration['exceptions'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList()
          : _result?.exceptions ?? const <Map<String, dynamic>>[];
      final exceptionsRevision =
          _configuration.containsKey('exceptionsRevision')
          ? _configuration['exceptionsRevision']?.toString()
          : _result?.exceptionsRevision;
      final values = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => AiRequirementsEditor(
          options: options,
          requirements: requirements,
          exceptions: exceptions,
          exceptionsRevision: exceptionsRevision,
        ),
      );
      if (values != null && mounted) {
        setState(() {
          _configuration = values;
          _requirementsChanged = true;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = aiErrorText(e.code, e.message));
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取任务，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _undo(AiApplication application) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这次应用？'),
        content: const Text('将恢复应用前的排期。如果相关任务已被修改或恢复位置被占用，整次撤销会停止。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await (widget.repository as AdvancedAiPlannerRepository).undoApplication(
        application.id,
      );
      if (!mounted) return;
      setState(() {
        _applications = _applications
            .map(
              (a) => a.id == application.id
                  ? AiApplication(
                      id: a.id,
                      status: 'undone',
                      applied: a.applied,
                      draftId: a.draftId,
                    )
                  : a,
            )
            .toList();
        final current = _result;
        if (current != null && current.draft.id == application.draftId) {
          _result = current.withDraft(
            AiDraft(
              id: current.draft.id,
              status: 'undone',
              changes: const [],
              warnings: const [],
            ),
            summary: '这次应用已撤销，日程已恢复。',
          );
          _canContinue = false;
        } else if (current?.draft.status == 'pending') {
          _result = current!.withDraft(
            current.draft,
            summary: '这次应用已撤销，下面保留尚未应用的安排。',
          );
        }
      });
      widget.onApplied?.call();
      unawaited(_loadHistory());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = aiErrorText(e.code, e.message));
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法确认撤销结果，请从历史记录核对或重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showIntro) {
      return SingleChildScrollView(controller: _scroll, child: _intro());
    }
    final scheme = Theme.of(context).colorScheme;
    final advanced = widget.repository is AdvancedAiPlannerRepository;
    final result = _result;
    final selectable =
        advanced && result?.draft.status == 'pending' && !_requirementsChanged;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 6, 6),
          child: Row(
            children: [
              const Text('🎀', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 9),
              const Expanded(
                child: Text(
                  'AI 计划助手',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: '额度与说明',
                onPressed: () => setState(() => _showInfo = !_showInfo),
                icon: const Icon(Icons.info_outline, size: 20),
              ),
              IconButton(
                tooltip: _showHistory ? '返回当前方案' : '历史记录',
                onPressed: _loading
                    ? null
                    : () {
                        setState(() => _showHistory = !_showHistory);
                        if (_showHistory) unawaited(_loadHistory());
                      },
                icon: Icon(
                  _showHistory ? Icons.chat_bubble_outline : Icons.history,
                  size: 22,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: _close,
                icon: const Icon(Icons.close, size: 22),
              ),
            ],
          ),
        ),
        Expanded(
          child: _showHistory
              ? _historyView()
              : ListView(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  children: [
                    if (_showInfo)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          _betaCopy,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (result == null) ...[
                      const SizedBox(height: 12),
                      const Text(
                        '把想做的事，排进时间里',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '说说任务和时间偏好，先看方案，再由你确认。',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final suggestion in const {
                            '安排今天': '安排今天剩余任务',
                            '本周 DDL': '规划本周 DDL',
                            '留复习时间': '给我留出复习时间',
                          }.entries)
                            ActionChip(
                              label: Text(suggestion.key),
                              onPressed: () => setState(
                                () => _input.text = suggestion.value,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (advanced)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _loading ? null : _editRequirements,
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('本次要求'),
                          ),
                        ),
                      if (_history.any((h) => h.hasPendingDraft))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.restore),
                          title: const Text('继续尚未确认的安排'),
                          onTap: () => setState(() => _showHistory = true),
                        ),
                    ],
                    for (final entry in _transcript)
                      Align(
                        alignment: entry.user
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          constraints: const BoxConstraints(maxWidth: 480),
                          decoration: BoxDecoration(
                            color: entry.user
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            aiSafeText(entry.text),
                            style: TextStyle(
                              color: entry.user
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurface,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    if (result != null) ...[
                      if (result.requirements.isNotEmpty)
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 12),
                          title: const Text(
                            '本次要求',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${result.requirements.length} 项 · 可核对原话或修改',
                            style: const TextStyle(fontSize: 12),
                          ),
                          children: [
                            for (final r in result.requirements)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(r.label),
                                subtitle: Text(
                                  '${r.confirmed ? '已确认' : '待应用时确认'} · ${r.source}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            if (advanced)
                              TextButton(
                                onPressed: _loading ? null : _editRequirements,
                                child: const Text('修改本次要求'),
                              ),
                          ],
                        ),
                      if (result.requirements.isEmpty && advanced)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _loading ? null : _editRequirements,
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('本次要求'),
                          ),
                        ),
                      if (_requirementsChanged)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '本次要求已修改，请发送消息重新生成方案。',
                            style: TextStyle(color: scheme.primary),
                          ),
                        ),
                      if (_showPreviousResult)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '本次请求未完成，下方保留的是上一轮结果。',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      AiDraftPreview(
                        key: _previewKey,
                        result: result,
                        selectedIds: selectable ? _selected : null,
                        onSelectionChanged: selectable && !_loading
                            ? (id) => setState(() {
                                _selected.contains(id)
                                    ? _selected.remove(id)
                                    : _selected.add(id);
                              })
                            : null,
                      ),
                      for (final application in _applications)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  application.status == 'undone'
                                      ? '已撤销'
                                      : '已应用${application.applied > 0 ? ' ${application.applied} 项' : ''}',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              if (application.status == 'applied' && advanced)
                                TextButton(
                                  key: ValueKey('ai-undo-${application.id}'),
                                  onPressed: _loading
                                      ? null
                                      : () => _undo(application),
                                  child: const Text('撤销这次应用'),
                                ),
                            ],
                          ),
                        ),
                    ],
                    if (_loading)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          '正在规划，请稍等…',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
        ),
        if (!_showHistory &&
            result != null &&
            result.draft.status == 'pending' &&
            result.draft.changes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('ai-apply'),
                onPressed:
                    _loading ||
                        _requirementsChanged ||
                        (advanced && _selected.isEmpty)
                    ? null
                    : _apply,
                icon: const Icon(Icons.check, size: 18),
                label: Text(advanced ? '应用选中的 ${_selected.length} 项' : '应用安排'),
              ),
            ),
          ),
        _composer(),
      ],
    );
  }

  Widget _composer() {
    final scheme = Theme.of(context).colorScheme;
    final voiceActive = _voice.recording || _voice.busy;
    return Container(
      key: const ValueKey('ai-composer'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          if (_error?.contains('额度') == true)
            TextButton.icon(
              icon: const Icon(Icons.redeem_outlined, size: 18),
              label: const Text('兑换邀请码'),
              onPressed: _loading
                  ? null
                  : () async {
                      final redeemed = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => const AiInviteScreen(),
                        ),
                      );
                      if (redeemed == true && mounted) {
                        setState(() => _error = null);
                      }
                    },
            ),
          if (_retrySeconds > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '请等 $_retrySeconds 秒后再继续，你输入的内容已保留。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (voiceActive || _voice.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    _voice.recording ? Icons.mic : Icons.graphic_eq,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _voice.error ??
                          (_voice.recording
                              ? '正在聆听 · ${_voice.seconds}s / 60s'
                              : _voice.state == VoiceState.recognizing
                              ? '正在转成文字…'
                              : '正在准备麦克风…'),
                      style: TextStyle(
                        fontSize: 12,
                        color: _voice.error != null
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_voice.canRetry)
                    TextButton(
                      onPressed: _voice.retry,
                      child: const Text('重试'),
                    ),
                  if (voiceActive)
                    IconButton(
                      tooltip: '取消录音',
                      onPressed: _voice.cancel,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 3, 4, 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    onKeyEvent: _handleComposerKey,
                    child: TextField(
                      key: const ValueKey('ai-planner-input'),
                      controller: _input,
                      onTap: widget.onExpand,
                      minLines: 1,
                      maxLines: 3,
                      enabled: !_loading && !voiceActive,
                      decoration: InputDecoration(
                        hintText: _result == null || !_canContinue
                            ? '说说你想做什么…'
                            : '继续调整这份安排…',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _voice.recording ? '结束录音' : '语音输入',
                  onPressed: _loading || _voice.busy
                      ? null
                      : _voice.recording
                      ? _voice.finish
                      : _startVoice,
                  icon: Icon(
                    _voice.recording
                        ? Icons.stop_circle_outlined
                        : Icons.mic_none_rounded,
                    color: _voice.recording ? scheme.error : null,
                  ),
                ),
                IconButton.filled(
                  tooltip: _result == null || !_canContinue ? '生成安排' : '调整方案',
                  onPressed:
                      _loading ||
                          voiceActive ||
                          _showHistory ||
                          _retrySeconds > 0
                      ? null
                      : _submit,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward_rounded, size: 22),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyView() {
    if (_historyLoading && _history.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_history.isEmpty) {
      return const Center(child: Text('还没有历史安排'));
    }
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        itemCount: _history.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = _history[index];
          final title = item.firstMessage.trim().isEmpty
              ? '一次安排'
              : aiSafeText(item.firstMessage, fallback: '一次安排');
          final subtitle = item.summary.trim().isEmpty
              ? (item.hasPendingDraft ? '等待你确认' : _sessionStatus(item.status))
              : aiSafeText(item.summary, fallback: _sessionStatus(item.status));
          final stateLabel = item.hasPendingDraft
              ? '等待你确认'
              : _sessionStatus(item.status);
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: CircleAvatar(
                child: Icon(
                  item.hasPendingDraft
                      ? Icons.pending_actions_rounded
                      : Icons.auto_awesome_outlined,
                ),
              ),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '$subtitle · $stateLabel',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _restoreSession(item),
              trailing: IconButton(
                tooltip: '删除这条历史记录',
                onPressed: () => _deleteHistory(item),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          );
        },
      ),
    );
  }

  String _sessionStatus(AiSessionStatus status) => switch (status) {
    AiSessionStatus.active => '进行中',
    AiSessionStatus.applied => '已应用',
    AiSessionStatus.closed => '已保存',
    AiSessionStatus.expired => '已过期',
  };

  Widget _intro() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('🎀', style: TextStyle(fontSize: 44)),
        const SizedBox(height: 8),
        const Text(
          '让 AI 帮你整理时间',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        const Text('它会读取当前任务、DDL、排期和课程信息，生成一份可继续调整的草案。未经你确认，不会修改任何安排。'),
        const SizedBox(height: 12),
        const Text(_betaCopy),
        const SizedBox(height: 20),
        FilledButton(onPressed: _continueFromIntro, child: const Text('开始使用')),
      ],
    ),
  );
}
