import 'package:flutter/foundation.dart';

import '../core/pairing.dart';
import '../core/scanner.dart';
import '../core/transfer.dart';

enum DeviceRole { oldDevice, newDevice }

enum Transport { network, cable, usbDrive }

enum TransferMode { safe, recommended, wholeDisk, custom }

extension TransferModeInfo on TransferMode {
  String get title => switch (this) {
        TransferMode.safe => 'Safe Transfer',
        TransferMode.recommended => 'Recommended',
        TransferMode.wholeDisk => 'Whole Disk Clone',
        TransferMode.custom => 'Custom',
      };

  String get blurb => switch (this) {
        TransferMode.safe =>
          'Apps and your personal files. Nothing else. Safest choice.',
        TransferMode.recommended =>
          'Apps, files and your settings — accounts stay signed in, Wi-Fi just works.',
        TransferMode.wholeDisk =>
          'Everything, including the operating system. The new machine becomes this machine.',
        TransferMode.custom =>
          'Pick exactly what moves over, folder by folder.',
      };
}

/// Everything the wizard collects along the way, plus the live engine
/// controllers once a flow is underway.
class WizardState extends ChangeNotifier {
  DeviceRole? role;
  Transport? transport;
  TransferMode? mode;

  Session? session;
  SenderController? sender; // old computer, network
  ReceiverController? receiver; // new computer, network or bundle
  SenderController? exporter; // old computer, USB drive

  List<ScanCategory> cats = [];
  Set<String> selected = {};
  String? drivePath;

  void setRole(DeviceRole r) {
    role = r;
    notifyListeners();
  }

  void setTransport(Transport t) {
    transport = t;
    notifyListeners();
  }

  void applyMode(TransferMode m) {
    mode = m;
    if (m == TransferMode.safe) {
      selected = {
        for (final c in cats)
          if (c.available && !c.settings) c.id
      };
    } else if (m == TransferMode.recommended) {
      selected = {
        for (final c in cats)
          if (c.available) c.id
      };
    } else if (m == TransferMode.custom && selected.isEmpty) {
      selected = {
        for (final c in cats)
          if (c.available) c.id
      };
    }
    notifyListeners();
  }

  int get selectedBytes => cats
      .where((c) => selected.contains(c.id))
      .fold(0, (s, c) => s + c.sizeBytes);

  int bytesForMode(TransferMode m) => switch (m) {
        TransferMode.safe => cats
            .where((c) => c.available && !c.settings)
            .fold(0, (s, c) => s + c.sizeBytes),
        _ => cats
            .where((c) => c.available)
            .fold(0, (s, c) => s + c.sizeBytes),
      };

  void toggle(ScanCategory c) {
    if (selected.contains(c.id)) {
      selected.remove(c.id);
    } else {
      selected.add(c.id);
    }
    notifyListeners();
  }

  /// Back to the first screen; closes any live connection.
  void reset() {
    session?.close();
    session = null;
    sender = null;
    receiver = null;
    exporter = null;
    cats = [];
    selected = {};
    mode = null;
    transport = null;
    role = null;
    notifyListeners();
  }
}

String prettyBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(bytes % gb == 0 ? 0 : 1)} GB';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  return '${(bytes / 1024).round()} KB';
}
