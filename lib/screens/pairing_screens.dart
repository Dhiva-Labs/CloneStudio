import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/discovery.dart';
import '../core/identity.dart';
import '../core/pairing.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'connected_screen.dart';
import 'scan_screen.dart';

/// OLD computer: start the TLS server + discovery responder, show the PIN,
/// wait for the new computer to pair.
class PinDisplayScreen extends StatefulWidget {
  const PinDisplayScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<PinDisplayScreen> createState() => _PinDisplayScreenState();
}

class _PinDisplayScreenState extends State<PinDisplayScreen> {
  PairingServer? server;
  final advertiser = Advertiser();
  String? error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final identity = await Identity.load();
      final srv = PairingServer(identity);
      await srv.start();
      await advertiser.start(
          name: identity.deviceName,
          os: identity.osName,
          tlsPort: srv.port);
      srv.addListener(_onServerChanged);
      if (mounted) setState(() => server = srv);
    } catch (e) {
      if (mounted) {
        setState(() => error =
            'Something went wrong while getting ready. Please try again.');
      }
    }
  }

  void _onServerChanged() {
    final srv = server;
    if (srv == null || !mounted) return;
    final session = srv.session;
    if (session != null) {
      widget.state.session = session;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) =>
              ConnectedScreen(state: widget.state, peerName: session.peerName)));
    } else {
      setState(() {}); // PIN may have been regenerated
    }
  }

  @override
  void dispose() {
    server?.removeListener(_onServerChanged);
    advertiser.stop();
    server?.stop(); // stops listening; an established session stays open
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final srv = server;
    return WizardScaffold(
      title: 'Ready and waiting',
      subtitle:
          'On your NEW computer, open Clone Studio and type this code when asked.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(error!, textAlign: TextAlign.center),
              ),
            )
          else if (srv == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              ),
            )
          else
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
                child: Column(
                  children: [
                    Text(
                      srv.pin.split('').join('  '),
                      style: TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4,
                        color: scheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _WaitingDots(),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaitingDots extends StatefulWidget {
  const _WaitingDots();

  @override
  State<_WaitingDots> createState() => _WaitingDotsState();
}

class _WaitingDotsState extends State<_WaitingDots> {
  int dots = 1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500),
        (_) => setState(() => dots = dots % 3 + 1));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text('Waiting for your new computer${'.' * dots}',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.color
                ?.withValues(alpha: 0.6)));
  }
}

/// NEW computer: live device list from UDP discovery.
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  final browser = Browser();

  @override
  void initState() {
    super.initState();
    browser.start();
  }

  @override
  void dispose() {
    browser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: browser,
      builder: (context, _) {
        final devices = browser.devices.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        final found = devices.isNotEmpty;
        return WizardScaffold(
          title: found ? 'Found it!' : 'Looking for your old computer…',
          subtitle: found
              ? 'Tap your old computer to connect.'
              : 'Make sure Clone Studio is open on the old computer too.',
          child: found
              ? SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final d in devices) ...[
                        BigChoiceCard(
                          emoji: '💻',
                          title: d.name,
                          description: '${d.os} · found on your network',
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => PinEntryScreen(
                                      state: widget.state, device: d))),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ],
                  ),
                )
              : const Center(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(strokeWidth: 5),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// NEW computer: TV-login style six-box PIN entry, wired to the real
/// pairing handshake.
class PinEntryScreen extends StatefulWidget {
  const PinEntryScreen({super.key, required this.state, required this.device});
  final WizardState state;
  final RemoteDevice device;

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String value) async {
    setState(() => error = null);
    if (value.length != 6 || busy) return;
    setState(() => busy = true);
    try {
      final session = await PairingClient.pair(widget.device, value,
          myName: Platform.localHostname);
      widget.state.session = session;
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ScanScreen(state: widget.state, local: false)));
      setState(() {
        busy = false;
        _controller.clear();
      });
    } on PairingException catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = e.friendly;
        _controller.clear();
      });
      // The field is disabled while busy; refocus only works after the
      // rebuild that re-enables it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final digits = _controller.text;
    return WizardScaffold(
      title: 'Type the code',
      subtitle:
          "Enter the 6-digit code shown on your old computer's screen.",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque, // taps between boxes count too
            onTap: () => _focus.requestFocus(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (i) {
                final filled = i < digits.length;
                final active = i == digits.length && !busy;
                return Container(
                  width: 58,
                  height: 72,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardTheme.color,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: active
                          ? scheme.primary
                          : scheme.outline.withValues(alpha: 0.3),
                      width: active ? 2.5 : 1,
                    ),
                  ),
                  child: Text(
                    filled ? digits[i] : '',
                    style: const TextStyle(
                        fontSize: 32, fontWeight: FontWeight.w700),
                  ),
                );
              }),
            ),
          ),
          // Hidden field that actually captures keyboard input.
          SizedBox(
            width: 1,
            height: 1,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: !busy,
              onChanged: _onChanged,
              decoration: const InputDecoration(counterText: ''),
              style: const TextStyle(color: Colors.transparent, height: 0.1),
              cursorColor: Colors.transparent,
            ),
          ),
          const SizedBox(height: 24),
          if (busy) const CircularProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: scheme.error, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
