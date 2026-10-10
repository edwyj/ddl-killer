import 'dart:js_interop';
@JS('ddlPush.permission') external JSPromise<JSBoolean> _permission();
@JS('ddlPush.activate') external JSPromise<JSAny?> _activate(JSString token, JSString key);
@JS('ddlPush.enabled') external JSPromise<JSBoolean> _enabled();
@JS('ddlPush.clear') external JSPromise<JSAny?> _clear(JSString token);
@JS('ddlPush.test') external JSPromise<JSAny?> _test();
Future<bool> requestPermission() async => (await _permission().toDart).toDart;
Future<bool> requestNotificationPermission() async => requestPermission();
Future<void> activate(String token, String key) async { await _activate(token.toJS,key.toJS).toDart; }
Future<bool> enabled() async => (await _enabled().toDart).toDart;
Future<void> synchronize(List<dynamic> tasks) async {}
Future<void> clear(String? token) async { await _clear((token ?? '').toJS).toDart; }
Future<void> testNotification() async { await _test().toDart; }
