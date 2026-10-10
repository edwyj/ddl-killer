import 'dart:js_interop';

@JS('ddlOffline.prepare')
external JSPromise<JSBoolean> _prepare();
@JS('ddlOffline.persist')
external JSPromise<JSBoolean> _persist();
@JS('ddlOffline.watch')
external void _watch(JSFunction callback);
@JS('ddlOffline.pending')
external void _pending(JSNumber count);
Future<void> prepare() async {
  if (!(await _prepare().toDart).toDart) {
    throw StateError('已在其他标签页打开，请关闭其他 DDL Killer 页面后重试');
  }
}

Future<bool> requestPersistence() async => (await _persist().toDart).toDart;
void watch(void Function() online) => _watch(online.toJS);
void setPending(int count) => _pending(count.toJS);
@JS('ddlOffline.shellReady')
external JSBoolean _shellReady();
bool get shellReady => _shellReady().toDart;
@JS('ddlOffline.update')
external JSPromise<JSAny?> _update();
Future<void> updateApp() async {
  await _update().toDart;
}
