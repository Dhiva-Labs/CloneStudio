import 'package:flutter/material.dart';

import 'models/wizard_state.dart';
import 'screens/role_screen.dart';
import 'theme.dart';

void main() {
  runApp(const CloneStudioApp());
}

class CloneStudioApp extends StatefulWidget {
  const CloneStudioApp({super.key});

  @override
  State<CloneStudioApp> createState() => _CloneStudioAppState();
}

class _CloneStudioAppState extends State<CloneStudioApp> {
  final state = WizardState();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clone Studio',
      theme: CsTheme.light(),
      darkTheme: CsTheme.dark(),
      home: RoleScreen(state: state),
    );
  }
}
