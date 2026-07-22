import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// Device TLS identity: a self-signed certificate generated once with openssl
/// and reused forever. The PIN handshake binds pairing to this certificate's
/// fingerprint, which makes trust-on-first-use safe against man-in-the-middle.
class Identity {
  Identity._(this.context, this.fingerprint, this.deviceName, this.osName);

  final SecurityContext context;
  final List<int> fingerprint; // SHA-256 of the DER-encoded certificate
  final String deviceName;
  final String osName;

  static Future<Identity> load() async {
    final home = Platform.environment['HOME'] ?? '.';
    final dir = Directory('$home/.local/share/clone_studio');
    await dir.create(recursive: true);
    final keyPath = '${dir.path}/key.pem';
    final certPath = '${dir.path}/cert.pem';

    if (!File(keyPath).existsSync() || !File(certPath).existsSync()) {
      final host = Platform.localHostname;
      final res = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes',
        '-days', '3650', '-keyout', keyPath, '-out', certPath,
        '-subj', '/CN=$host/O=Clone Studio',
      ]);
      if (res.exitCode != 0) {
        throw StateError('Could not create a secure identity: ${res.stderr}');
      }
    }

    final context = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);

    final der = _pemToDer(await File(certPath).readAsString());
    final fingerprint = crypto.sha256.convert(der).bytes;

    return Identity._(
        context, fingerprint, Platform.localHostname, await _prettyOs());
  }

  static List<int> _pemToDer(String pem) {
    final body = pem
        .split('\n')
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return base64.decode(body);
  }

  static Future<String> _prettyOs() async {
    try {
      final text = await File('/etc/os-release').readAsString();
      for (final line in text.split('\n')) {
        if (line.startsWith('PRETTY_NAME=')) {
          return line.substring('PRETTY_NAME='.length).replaceAll('"', '');
        }
      }
    } catch (_) {}
    return 'Linux';
  }
}
