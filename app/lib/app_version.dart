import 'build_channel.dart';

// Keep aligned with pubspec.yaml; verified when building the release manifest.
abstract final class AppVersion {
  static const name = '0.13.2';
  static const displayName = BuildChannel.beta ? BuildChannel.version : name;
  static const build = 60;
  static const notes =
      '优化图形验证码的圆角和显示效果，统一注册与找回密码的样式。支持点击图片换一张，并改善加载与重试提示。';
}
