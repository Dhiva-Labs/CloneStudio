import 'package:flutter/material.dart';

import '../core/transfer.dart';
import '../models/wizard_state.dart';
import '../widgets/common.dart';
import 'file_tree_screen.dart';
import 'transfer_screen.dart';

/// NEW computer, right after pairing: fetch what the old computer wants to
/// send, then let the user review and trim it before anything is written.
class ReceiveOfferScreen extends StatefulWidget {
  const ReceiveOfferScreen({super.key, required this.state});
  final WizardState state;

  @override
  State<ReceiveOfferScreen> createState() => _ReceiveOfferScreenState();
}

class _ReceiveOfferScreenState extends State<ReceiveOfferScreen> {
  String? error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final st = widget.state;
    final receiver = ReceiverController(st.session!, st.session!);
    st.receiver = receiver;
    final ok = await receiver.receiveOffer();
    if (!ok) {
      if (mounted) {
        setState(() => error = receiver.errorMessage ??
            'Something went wrong. Please go back and try again.');
      }
      return;
    }
    st.buildSelectionFromOffer(receiver.offerCats, receiver.offerLeaves);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => FileTreeScreen(
        state: st,
        title: 'Review what’s coming',
        subtitle:
            'From ${receiver.peerName.isEmpty ? 'the old computer' : receiver.peerName}. '
            'Untick anything you don’t want on this computer.',
        continueLabel: 'Bring it over',
        onContinue: (ctx, s) {
          Navigator.of(ctx).pushReplacement(MaterialPageRoute(
            builder: (_) => TransferScreen(
              state: s,
              source: receiver,
              sending: false,
              starter: () => receiver.startReceive(s.includedRels()),
            ),
          ));
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      title: error == null ? 'Getting the list…' : 'Hmm, that didn’t work',
      subtitle: error ??
          'Seeing what your old computer wants to send over. One moment.',
      child: error == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: SizedBox(
                    width: 64,
                    height: 64,
                    child: CircularProgressIndicator(strokeWidth: 5)),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
