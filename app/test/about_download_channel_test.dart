import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/build_channel.dart';

void main() {
  test('About download page follows the compiled release channel', () {
    expect(
      BuildChannel.downloadPage.toString(),
      BuildChannel.beta
          ? 'https://beta.ddlkiller.com/download/'
          : 'https://ddlkiller.com/download.html',
    );
  });
}
