import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'data/db.dart';
import 'state/app_state.dart';
import 'state/device_controller.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PcgKolectApp());
}

Future<AppState> _load() async {
  final db = await AppDb.open();
  // app-private storage; file names are opaque recording IDs (no participant data)
  final root = (await getApplicationSupportDirectory()).path;
  final app = AppState(db, root);
  await app.load();
  return app;
}

class PcgKolectApp extends StatefulWidget {
  const PcgKolectApp({super.key});
  @override
  State<PcgKolectApp> createState() => _PcgKolectAppState();
}

class _PcgKolectAppState extends State<PcgKolectApp> {
  AppState? app;

  @override
  void initState() {
    super.initState();
    // the splash stays at least this long so it reads as a splash, not a flicker
    Future.wait([_load(), Future.delayed(const Duration(milliseconds: 1200))]).then((r) {
      if (mounted) setState(() => app = r[0] as AppState);
    });
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E6E), brightness: b),
          useMaterial3: true,
        );
    MaterialApp materialApp(Widget home) => MaterialApp(
          title: 'PCGKolect',
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: home,
        );
    if (app == null) return materialApp(const SplashScreen());
    // providers sit above MaterialApp so pushed routes see them too
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: app!),
        ChangeNotifierProvider(create: (_) => DeviceController()),
      ],
      child: materialApp(const HomeShell()),
    );
  }
}

/// Continues the native launch screen (same white background and logo).
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.6,
          child: Image.asset('assets/branding/logo_full.png', semanticLabel: 'PCGKollect'),
        ),
      ),
    );
  }
}
