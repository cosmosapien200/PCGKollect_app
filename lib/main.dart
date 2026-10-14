import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'data/db.dart';
import 'state/app_state.dart';
import 'state/device_controller.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDb.open();
  // app-private storage; file names are opaque recording IDs (no participant data)
  final root = (await getApplicationSupportDirectory()).path;
  final app = AppState(db, root);
  await app.load();
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: app),
      ChangeNotifierProvider(create: (_) => DeviceController()),
    ],
    child: const PcgKolectApp(),
  ));
}

class PcgKolectApp extends StatelessWidget {
  const PcgKolectApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E6E), brightness: b),
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'PCGKolect',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const HomeShell(),
    );
  }
}
