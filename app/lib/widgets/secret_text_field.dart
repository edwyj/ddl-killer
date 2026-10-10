import 'package:flutter/material.dart';

enum SecretKind { password, apiKey }

class SecretTextField extends StatefulWidget {
  const SecretTextField({
    super.key,
    required this.controller,
    required this.labelText,
    this.helperText,
    this.enabled,
    this.onSubmitted,
    this.secretKind = SecretKind.password,
    this.border = const OutlineInputBorder(),
  });

  final TextEditingController controller;
  final String labelText;
  final String? helperText;
  final bool? enabled;
  final ValueChanged<String>? onSubmitted;
  final SecretKind secretKind;
  final InputBorder? border;

  @override
  State<SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<SecretTextField> {
  bool _obscure = true;

  String get _showLabel =>
      widget.secretKind == SecretKind.apiKey ? '显示 Key' : '显示密码';
  String get _hideLabel =>
      widget.secretKind == SecretKind.apiKey ? '隐藏 Key' : '隐藏密码';

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: _obscure,
    autocorrect: false,
    enableSuggestions: false,
    onSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.labelText,
      helperText: widget.helperText,
      helperMaxLines: 3,
      border: widget.border,
      suffixIcon: Semantics(
        label: _obscure ? _showLabel : _hideLabel,
        button: true,
        excludeSemantics: true,
        child: IconButton(
          tooltip: _obscure ? _showLabel : _hideLabel,
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          ),
        ),
      ),
    ),
  );
}
