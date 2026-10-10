import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/auth_store.dart';
import 'package:plan_app/network_client.dart';

void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 setUp((){SharedPreferences.setMockInitialValues({});FlutterSecureStorage.setMockInitialValues({});});
 test('native credentials use secure storage and remove legacy plaintext; logout removes caches',()async{
  SharedPreferences.setMockInitialValues({'auth_token':'old','read_cache_v1_host_1_x':'private','theme_mode':'dark'});
  expect(await AuthStore.loadToken(),isNull);
  await AuthStore.saveToken('new-session');
  final prefs=await SharedPreferences.getInstance();
  expect(prefs.getString('auth_token'),isNull);
  expect(await AuthStore.loadToken(),'new-session');
  await AuthStore.clear();
  expect(await AuthStore.loadToken(),isNull);
  expect(prefs.getKeys().any((k)=>k.startsWith('read_cache_v1_')),isFalse);
  expect(prefs.getString('theme_mode'),'dark');
 });
 test('an in-flight response cannot restore private cache after clearing',()async{
  final pending=Completer<http.Response>();
  final net=NetworkClient(clientFactory:()=>MockClient((_)=>pending.future));
  final token='x.${base64Url.encode(utf8.encode(jsonEncode({'uid':1,'exp':4102444800})))}.x';
  final request=net.request('GET',Uri.parse('https://example.test/api/inbox'),token);
  final assertion=expectLater(request,throwsA(isA<ApiException>()));
  await net.clearCache();pending.complete(http.Response('[{"title":"private"}]',200));
  await assertion;
  expect((await SharedPreferences.getInstance()).getKeys(),isEmpty);
 });
}
