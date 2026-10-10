import 'package:sembast_web/sembast_web.dart';

Future<Database> openOfflineDatabase() =>
    databaseFactoryWeb.openDatabase('ddl-offline-v1');
