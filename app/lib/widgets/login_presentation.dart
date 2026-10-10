import 'package:flutter/material.dart';

import 'app_logo.dart';
import 'login_appearance_switch.dart';

/// Shared responsive entry surface. Authentication remains in LoginScreen.
class LoginPresentation extends StatelessWidget {
  const LoginPresentation({
    super.key,
    required this.registering,
    required this.form,
  });
  final bool registering;
  final WidgetBuilder form;
  static const ink = Color(0xFF342D37);
  static const pink = Color(0xFFDC5D77);
  static const violet = Color(0xFF8D70CC);
  static const mint = Color(0xFF34967E);
  static const wideBreakpoint = 960.0;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final dark = base.brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: pink,
          brightness: base.brightness,
        ).copyWith(
          primary: dark ? const Color(0xFFF0AEC0) : const Color(0xFF97435F),
          onSurface: dark ? const Color(0xFFF4EDF4) : ink,
          onSurfaceVariant: dark
              ? const Color(0xFFC6BAC8)
              : const Color(0xFF756B78),
        );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: .13)),
    );
    final theme = base.copyWith(
      colorScheme: scheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF302A33) : const Color(0xBFFFFFFF),
        hoverColor: pink.withValues(alpha: .035),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: const BorderSide(color: violet, width: 1.5),
        ),
        errorBorder: border.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: border.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        disabledBorder: border.copyWith(
          borderSide: BorderSide(
            color: scheme.onSurface.withValues(alpha: .06),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
      ),
    );
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: dark
              ? const Color(0xFF201C24)
              : const Color(0xFFFFFDFD),
          body: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-.9, -.8),
                        radius: 1.2,
                        colors: [
                          pink.withValues(alpha: dark ? .10 : .09),
                          pink.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(.9, -.1),
                        radius: 1,
                        colors: [
                          violet.withValues(alpha: .08),
                          violet.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-.3, 1),
                        radius: .9,
                        colors: [
                          mint.withValues(alpha: .055),
                          mint.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= wideBreakpoint;
                    final card = Container(
                      width: 420,
                      padding: EdgeInsets.all(wide ? 36 : 24),
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xD92A242F)
                            : const Color(0xB8FFFFFF),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: scheme.onSurface.withValues(alpha: .055),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: dark ? .08 : .025,
                            ),
                            blurRadius: 40,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!wide) ...[
                              const Center(child: _BrandLogo()),
                              const SizedBox(height: 12),
                              const Text(
                                'DDL Killer',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 26),
                            ],
                            Text(
                              registering ? '创建账号' : '欢迎回来',
                              textAlign: wide
                                  ? TextAlign.start
                                  : TextAlign.center,
                              style: const TextStyle(
                                fontSize: 27,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              registering ? '从今天开始，安排你的计划。' : '继续安排今天。',
                              textAlign: wide
                                  ? TextAlign.start
                                  : TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 28),
                            form(context),
                          ],
                        ),
                      ),
                    );
                    return ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(
                          horizontal: constraints.maxWidth < 360 ? 12 : 24,
                          vertical: 56,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (constraints.maxHeight - 112).clamp(
                              0,
                              double.infinity,
                            ),
                          ),
                          child: Center(
                            child: wide
                                ? ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1040,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: _BrandPanel(scheme: scheme),
                                        ),
                                        const SizedBox(width: 80),
                                        card,
                                      ],
                                    ),
                                  )
                                : card,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                top: 8,
                right: 16,
                child: SafeArea(child: const LoginAppearanceSwitch()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo();
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: const Color(0x0C342D37)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0C342D37),
          blurRadius: 16,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: const AppLogo(size: 60),
    ),
  );
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.scheme});
  final ColorScheme scheme;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _BrandLogo(),
        const SizedBox(height: 18),
        const Text(
          'DDL Killer',
          style: TextStyle(fontSize: 29, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 34),
        const Text(
          '你说想做什么，\nAI 帮你排进时间里',
          style: TextStyle(
            fontSize: 30,
            height: 1.65,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 26),
        Text(
          '🎀  Alice · 陪你安排每一天',
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 34),
        for (final item in [
          ('14:30', '专业英语', LoginPresentation.violet),
          ('16:30', '报告 · 完成初稿', LoginPresentation.pink),
          ('19:30', '高数复习', LoginPresentation.mint),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 54,
                  child: Text(
                    item.$1,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: .65),
                    ),
                  ),
                ),
                Container(
                  width: 3,
                  height: 27,
                  decoration: BoxDecoration(
                    color: item.$3.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  item.$2,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant.withValues(alpha: .75),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class LoginSubmitButton extends StatelessWidget {
  const LoginSubmitButton({
    super.key,
    required this.busy,
    required this.label,
    required this.onPressed,
  });
  final bool busy;
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: const [Color(0xFFDF5D78), Color(0xFF9170CD)],
      ),
    ),
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white,
        shadowColor: Colors.transparent,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: Theme.of(context).textTheme.labelLarge!
            .copyWith(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: busy
            ? Row(
                key: const ValueKey('busy'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(label == '注册' ? '正在注册…' : '正在登录…'),
                ],
              )
            : Text(label, key: const ValueKey('ready')),
      ),
    ),
  );
}
