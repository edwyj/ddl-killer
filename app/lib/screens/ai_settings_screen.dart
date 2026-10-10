import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models/ai_planner.dart';
import '../ai_ribbon_preferences.dart';
import '../widgets/secret_text_field.dart';
import '../ai_assistant_state.dart';
import '../ai_usage_policy.dart';
import 'ai_invite_screen.dart';
import 'ai_planning_preferences_screen.dart';

abstract class AiSettingsRepository {
  Future<AiAssistantSettings> load();
  Future<void> setMode(AiProviderMode mode, {String? password});
  Future<AiProviderSummary> saveProvider(AiProviderInput input);
  Future<void> testProvider({String? password});
  Future<void> deleteProvider({String? password});
}

class ApiAiSettingsRepository implements AiSettingsRepository {
  const ApiAiSettingsRepository();

  @override
  Future<AiAssistantSettings> load() => aiAssistantState.load();
  @override
  Future<void> setMode(AiProviderMode mode, {String? password}) async {
    await Api.instance.setAiMode(mode, password: password);
    await aiAssistantState.refresh();
  }

  @override
  Future<AiProviderSummary> saveProvider(AiProviderInput input) async {
    final result = await Api.instance.saveAiProvider(input);
    await aiAssistantState.refresh();
    return result;
  }

  @override
  Future<void> testProvider({String? password}) =>
      Api.instance.testAiProvider(password: password);
  @override
  Future<void> deleteProvider({String? password}) async {
    await Api.instance.deleteAiProvider(password: password);
    await aiAssistantState.refresh();
  }
}

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({
    super.key,
    this.repository = const ApiAiSettingsRepository(),
  });

  final AiSettingsRepository repository;

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _baseUrl = TextEditingController(text: 'https://api.deepseek.com/v1');
  static const _deepSeekModel = 'deepseek-flash';
  static final _keyHelp = Uri.parse(
    'https://ddlkiller.com/website/api-key-help.html',
  );
  final _model = TextEditingController(text: _deepSeekModel);
  final _key = TextEditingController();
  final _password = TextEditingController();
  final _customEmoji = TextEditingController();
  AiAssistantSettings? _settings;
  String _provider = 'deepseek';
  bool _loading = true;
  bool _busy = false;
  bool _needsPassword = false;
  String? _error;
  AiRibbonPreferences? _ribbon;

  @override
  void initState() {
    super.initState();
    _load();
    AiRibbonPreferences.shared().then((value) {
      if (!mounted) return;
      value.addListener(_ribbonChanged);
      setState(() => _ribbon = value);
    });
  }

  @override
  void dispose() {
    _key.clear();
    _password.clear();
    _ribbon?.removeListener(_ribbonChanged);
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _password.dispose();
    _customEmoji.dispose();
    super.dispose();
  }

  void _ribbonChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final settings = await widget.repository.load();
      if (!mounted) return;
      final provider = settings.provider;
      setState(() {
        _settings = settings;
        _provider = provider?.provider ?? 'deepseek';
        _baseUrl.text = provider?.baseUrl ?? 'https://api.deepseek.com/v1';
        _model.text = provider?.model ?? _deepSeekModel;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'AI 设置加载失败，请检查网络';
        });
      }
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _openKeyHelp() async {
    try {
      if (await launchUrl(_keyHelp, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // Keep the form intact when this device cannot open a browser.
    }
    _message('无法打开教程，请访问 ddlkiller.com/website/api-key-help.html');
  }

  Future<bool> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return true;
      _password.clear();
      setState(() => _needsPassword = false);
      _message(success);
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      if (error.code == 'RECENT_AUTH_REQUIRED') {
        setState(() => _needsPassword = true);
      }
      _message(error.message);
      return false;
    } catch (_) {
      _message('操作失败，请检查网络后重试');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMode(AiProviderMode mode) async {
    if (_settings?.mode == mode) return;
    final ok = await _run(
      () => widget.repository.setMode(mode, password: _password.text),
      mode == AiProviderMode.hosted ? '已使用官方测试额度' : '已使用自己的模型服务',
    );
    if (ok && mounted) {
      setState(() => _settings = _settings!.copyWith(mode: mode));
    }
  }

  Future<bool> _confirmCustomDomain() async {
    final uri = Uri.tryParse(_baseUrl.text.trim());
    if (uri?.host.isEmpty != false) {
      _message('请输入有效的 HTTPS API 地址');
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认 API Key 接收方'),
            content: Text('你的 API Key 将发送到 ${uri!.host}。请确认这是你信任的模型服务域名。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认并保存'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    if (_key.text.isEmpty) return _message('请输入新的 API Key');
    if (_provider == 'custom' && !await _confirmCustomDomain()) return;
    AiProviderSummary? saved;
    final ok = await _run(() async {
      saved = await widget.repository.saveProvider(
        AiProviderInput(
          provider: _provider,
          baseUrl: _baseUrl.text.trim(),
          model: _model.text.trim(),
          key: _key.text,
          password: _password.text,
        ),
      );
    }, '模型配置已安全保存');
    if (ok && mounted) {
      _key.clear();
      setState(() => _settings = _settings!.copyWith(provider: saved));
    }
  }

  Future<void> _test() => _run(
    () => widget.repository.testProvider(password: _password.text),
    '连接测试成功',
  );

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型配置？'),
        content: const Text('这里只会删除 DDL Killer 保存的密文。如 Key 可能泄漏，还需要到提供商控制台撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await _run(
      () => widget.repository.deleteProvider(password: _password.text),
      '模型配置已删除',
    );
    if (ok && mounted) {
      setState(() => _settings = _settings!.copyWith(clearProvider: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 计划助手')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (!_settings!.featureEnabled)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.science_outlined),
                      title: Text('AI 计划助手尚未开放'),
                      subtitle: Text('当前仍可查看和准备模型配置，正式开放后悬浮入口会自动出现。'),
                    ),
                  ),
                _quotaCard(),
                if (_ribbon != null) ...[
                  const SizedBox(height: 12),
                  _ribbonCard(),
                ],
                const SizedBox(height: 16),
                Text('模型来源', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<AiProviderMode>(
                  segments: const [
                    ButtonSegment(
                      value: AiProviderMode.hosted,
                      label: Text('官方额度'),
                      icon: Icon(Icons.auto_awesome_outlined),
                    ),
                    ButtonSegment(
                      value: AiProviderMode.byok,
                      label: Text('使用自己的 Key'),
                      icon: Icon(Icons.key_outlined),
                    ),
                  ],
                  selected: {_settings!.mode},
                  onSelectionChanged: _busy
                      ? null
                      : (value) => _setMode(value.first),
                ),
                if (_needsPassword &&
                    _settings!.mode == AiProviderMode.hosted) ...[
                  const SizedBox(height: 12),
                  _passwordField(),
                ],
                if (_settings!.mode == AiProviderMode.byok) ...[
                  const SizedBox(height: 20),
                  _providerForm(),
                ],
              ],
            ),
    );
  }

  Widget _quotaCard() {
    final quota = _settings!.quota;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '今日还可免费生成 ${quota.remaining} 次',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('每日总额度 ${quota.limit} 次 · 今日已用 ${quota.used} 次'),
            for (final grant in quota.entitlements)
              Text(
                '${grant.name} · 每天 ${grant.dailyLimit} 次 · ${grant.expiresAt.toLocal().toString().substring(0, 16)} 到期',
              ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final redeemed = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => const AiInviteScreen(),
                        ),
                      );
                      if (redeemed == true && mounted) {
                        await _load();
                      }
                    },
              icon: const Icon(Icons.redeem_outlined),
              label: const Text('兑换码'),
            ),
            TextButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AiPlanningPreferencesScreen(),
                ),
              ),
              icon: const Icon(Icons.schedule_outlined),
              label: const Text('安排偏好'),
            ),
            Text(
              aiUsagePolicyCopy,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ribbonCard() {
    const presets = ['🎀', '✨', '🤖', '🪄'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示悬浮入口'),
              subtitle: const Text('默认显示，可拖动并自动吸附屏幕边缘'),
              value: _ribbon!.enabled,
              onChanged: _ribbon!.setEnabled,
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final emoji in presets)
                  ChoiceChip(
                    label: Text(emoji, style: const TextStyle(fontSize: 20)),
                    selected: _ribbon!.emoji == emoji,
                    onSelected: (_) => _ribbon!.setEmoji(emoji),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _customEmoji,
              decoration: const InputDecoration(
                labelText: '自定义单个 Emoji',
                suffixText: '回车保存',
              ),
              onSubmitted: (value) async {
                if (!await _ribbon!.setEmoji(value.trim())) {
                  _message('请输入一个 Emoji');
                } else {
                  _customEmoji.clear();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _providerForm() {
    final summary = _settings!.provider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: _openKeyHelp,
          icon: const Icon(Icons.help_outline),
          label: const Text('API Key 获取与配置教程'),
        ),
        const Text('第一次配置？教程会带你获取 Key、填写配置并测试连接。'),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _provider,
          decoration: const InputDecoration(labelText: '提供商'),
          items: const [
            DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
            DropdownMenuItem(value: 'custom', child: Text('自定义 OpenAI 兼容服务')),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() {
                  _provider = value!;
                  if (value == 'deepseek') {
                    _baseUrl.text = 'https://api.deepseek.com/v1';
                    _model.text = _deepSeekModel;
                  }
                }),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('ai-base-url-field'),
          controller: _baseUrl,
          enabled: _provider == 'custom',
          decoration: const InputDecoration(labelText: 'API 地址'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          decoration: const InputDecoration(labelText: '模型名称'),
        ),
        const SizedBox(height: 12),
        SecretTextField(
          key: const ValueKey('ai-key-field'),
          controller: _key,
          labelText: 'API Key',
          helperText: summary == null
              ? '只在保存时发送，不会显示明文'
              : '已保存：${summary.keyMask}',
          secretKind: SecretKind.apiKey,
          border: const UnderlineInputBorder(),
        ),
        if (_needsPassword) ...[const SizedBox(height: 12), _passwordField()],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('保存配置'),
            ),
            OutlinedButton(
              onPressed: _busy || summary == null ? null : _test,
              child: const Text('测试连接'),
            ),
            TextButton(
              onPressed: _busy || summary == null ? null : _delete,
              child: const Text('删除配置'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _passwordField() => SecretTextField(
    key: const ValueKey('ai-password-field'),
    controller: _password,
    labelText: '账号密码',
    helperText: '登录时间较久，请验证密码后重试',
    border: const UnderlineInputBorder(),
  );
}
