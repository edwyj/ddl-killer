import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The server image has an opaque square background. Clip the entire surface,
/// including the SVG, so its corners stay smooth on every surrounding theme.
class CaptchaImage extends StatelessWidget {
  const CaptchaImage({
    super.key,
    required this.svg,
    required this.onRefresh,
    this.loading = false,
    this.width = 150,
    this.height = 56,
  });

  final String? svg;
  final VoidCallback? onRefresh;
  final bool loading;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final label = loading
        ? '正在加载验证码'
        : svg == null
        ? '重新加载验证码'
        : '换一张验证码';
    return Semantics(
      button: true,
      label: label,
      enabled: !loading && onRefresh != null,
      onTap: loading ? null : onRefresh,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: width,
          height: height,
          child: Material(
            // Keep the paper light: the server's coloured paths were generated
            // for this background, and inverting them hurts readability.
            color: const Color(0xFFF2F4F7),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Color(0xFFD9DDE5)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              excludeFromSemantics: true,
              onTap: loading ? null : onRefresh,
              child: Center(
                child: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF666C78),
                        ),
                      )
                    : svg == null
                    ? const Icon(
                        Icons.refresh,
                        size: 22,
                        color: Color(0xFF666C78),
                      )
                    : SvgPicture.string(
                        svg!,
                        width: width,
                        height: height,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
