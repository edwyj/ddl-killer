import 'package:flutter/material.dart';

import '../theme.dart';

/// Login appearance matches the lightweight menu on the public website.
class LoginAppearanceSwitch extends StatefulWidget {
  const LoginAppearanceSwitch({super.key});

  @override
  State<LoginAppearanceSwitch> createState() => _LoginAppearanceSwitchState();
}

class _LoginAppearanceSwitchState extends State<LoginAppearanceSwitch> {
  final _menu = MenuController();
  final _focus = FocusNode();

  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
  static IconData icon(ThemeMode mode) => switch (mode) {
    ThemeMode.system => Icons.brightness_6_outlined,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF302A33) : Colors.white;
    final selected = dark ? const Color(0xFF482D3B) : const Color(0xFFFBE4ED);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) => MenuAnchor(
        controller: _menu,
        childFocusNode: _focus,
        useRootOverlay: true,
        alignmentOffset: const Offset(0, 8),
        style: MenuStyle(
          alignment: Alignment.bottomRight,
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Color(0x30201428)),
          elevation: const WidgetStatePropertyAll(8),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
          minimumSize: const WidgetStatePropertyAll(Size(158, 0)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
              side: BorderSide(color: scheme.onSurface.withValues(alpha: .08)),
            ),
          ),
        ),
        menuChildren: [
          for (final choice in [
            ThemeMode.system,
            ThemeMode.light,
            ThemeMode.dark,
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: MenuItemButton(
                onPressed: () => ThemeController.set(choice),
                style: MenuItemButton.styleFrom(
                  backgroundColor: choice == mode
                      ? selected
                      : Colors.transparent,
                  foregroundColor: choice == mode
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  iconColor: choice == mode
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  iconSize: 18,
                  minimumSize: const Size(158, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(fontSize: 14),
                ),
                leadingIcon: Icon(icon(choice)),
                trailingIcon: choice == mode
                    ? const Icon(Icons.check, size: 17)
                    : const SizedBox(width: 17),
                child: Semantics(
                  selected: choice == mode,
                  child: Text(label(choice)),
                ),
              ),
            ),
        ],
        builder: (context, controller, _) => PopScope<Object?>(
          canPop: !controller.isOpen,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && controller.isOpen) controller.close();
          },
          child: Tooltip(
            message: '外观模式',
            child: TextButton(
              focusNode: _focus,
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              style: TextButton.styleFrom(
                backgroundColor: surface.withValues(alpha: dark ? .9 : .76),
                foregroundColor: scheme.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 8,
                ),
                minimumSize: const Size(0, 40),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(fontSize: 13),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon(mode), size: 18),
                  const SizedBox(width: 8),
                  Text(label(mode)),
                  const SizedBox(width: 6),
                  Icon(
                    controller.isOpen
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
