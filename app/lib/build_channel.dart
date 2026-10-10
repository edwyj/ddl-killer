abstract final class BuildChannel {
  static const beta = String.fromEnvironment('RELEASE_CHANNEL') == 'beta';
  static const version = String.fromEnvironment('BETA_VERSION');
  static const origin = 'https://beta.ddlkiller.com';
  static Uri get downloadPage => Uri.parse(
    beta ? '$origin/download/' : 'https://ddlkiller.com/download.html',
  );
  static const webRevision = String.fromEnvironment('WEB_REVISION');
}
