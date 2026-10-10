import 'dart:js_interop';

@JS('DDLTheme.read')
external JSString? _read();
@JS('DDLTheme.write')
external void _write(JSString value);
@JS('DDLTheme.watch')
external void _watch(JSFunction listener);

String? read() => _read()?.toDart;
void write(String value) => _write(value.toJS);
void watch(void Function(String) listener) =>
    _watch(((JSString value) => listener(value.toDart)).toJS);
