import 'package:flutter/material.dart';

import '../ai_ribbon_preferences.dart';

class AiRibbon extends StatefulWidget {
  const AiRibbon({
    super.key,
    required this.onOpen,
    required this.preferences,
    this.bottomInset = 8,
  });

  final VoidCallback onOpen;
  final AiRibbonPreferences preferences;
  final double bottomInset;

  @override
  State<AiRibbon> createState() => _AiRibbonState();
}

class _AiRibbonState extends State<AiRibbon> {
  static const _size = 52.0;
  static const _edge = 8.0;
  Offset? _pointerStart;
  Offset? _lastPointer;
  double? _dragLeft;
  double? _dragTop;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.preferences.addListener(_preferenceChanged);
  }

  @override
  void didUpdateWidget(covariant AiRibbon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences) {
      oldWidget.preferences.removeListener(_preferenceChanged);
      widget.preferences.addListener(_preferenceChanged);
    }
  }

  @override
  void dispose() {
    widget.preferences.removeListener(_preferenceChanged);
    super.dispose();
  }

  void _preferenceChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.preferences.enabled) return const SizedBox.shrink();
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxLeft = (constraints.maxWidth - _size - _edge).clamp(
            _edge,
            double.infinity,
          );
          final maxTop = (constraints.maxHeight - _size - widget.bottomInset)
              .clamp(_edge, double.infinity);
          final preferredLeft = widget.preferences.side == AiRibbonSide.left
              ? _edge
              : maxLeft;
          final preferredTop =
              _edge + widget.preferences.yFraction * (maxTop - _edge);
          final left = (_dragLeft ?? preferredLeft).clamp(_edge, maxLeft);
          final top = (_dragTop ?? preferredTop).clamp(_edge, maxTop);
          return Stack(
            children: [
              AnimatedPositioned(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                left: left,
                top: top,
                child: Semantics(
                  label: '打开 AI 计划助手',
                  button: true,
                  excludeSemantics: true,
                  onTap: widget.onOpen,
                  child: Listener(
                    onPointerDown: (event) {
                      _pointerStart = event.position;
                      _lastPointer = event.position;
                      _dragLeft = left;
                      _dragTop = top;
                      _dragging = true;
                    },
                    onPointerMove: (event) {
                      final last = _lastPointer;
                      if (last == null) return;
                      final delta = event.position - last;
                      _lastPointer = event.position;
                      setState(() {
                        _dragLeft = (_dragLeft! + delta.dx).clamp(
                          _edge,
                          maxLeft,
                        );
                        _dragTop = (_dragTop! + delta.dy).clamp(_edge, maxTop);
                      });
                    },
                    onPointerUp: (event) {
                      final distance = _pointerStart == null
                          ? 0.0
                          : (event.position - _pointerStart!).distance;
                      if (distance <= 8) {
                        widget.onOpen();
                        setState(() {
                          _dragLeft = null;
                          _dragTop = null;
                          _dragging = false;
                        });
                        return;
                      }
                      final side =
                          (_dragLeft! + _size / 2) < constraints.maxWidth / 2
                          ? AiRibbonSide.left
                          : AiRibbonSide.right;
                      final fraction = maxTop == _edge
                          ? 0.0
                          : (_dragTop! - _edge) / (maxTop - _edge);
                      widget.preferences.setPosition(side, fraction);
                      setState(() {
                        _dragLeft = null;
                        _dragTop = null;
                        _dragging = false;
                      });
                    },
                    onPointerCancel: (_) => setState(() {
                      _dragLeft = null;
                      _dragTop = null;
                      _dragging = false;
                    }),
                    child: AiRibbonHandle(emoji: widget.preferences.emoji),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class AiRibbonHandle extends StatelessWidget {
  const AiRibbonHandle({super.key, required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    return DecoratedBox(
      key: const ValueKey('ai-ribbon-surface'),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(scheme.surface, scheme.primary, light ? 0.025 : 0.08)!,
            Color.lerp(scheme.surface, scheme.primary, light ? 0.11 : 0.18)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: light
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.24),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: SizedBox(
        width: 52,
        height: 52,
        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 28))),
      ),
    );
  }
}
