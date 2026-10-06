import 'package:flutter/material.dart';

import 'src/database.dart';
import 'src/settings.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  runApp(NightdropApp(db: db, settingsStore: SettingsStore()));
}

class NightdropApp extends StatelessWidget {
  const NightdropApp({super.key, required this.db, required this.settingsStore});

  final AppDatabase db;
  final SettingsStore settingsStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nightdrop',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
      ),
      home: HomePage(db: db, settingsStore: settingsStore),
    );
  }
}
