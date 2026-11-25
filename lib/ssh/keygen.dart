import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

/// A key made on the phone: the private half goes into secure storage, the
/// public line goes into the host's `~/.ssh/authorized_keys`.
class GeneratedKey {
  GeneratedKey(this.privatePem, this.publicLine);
  final String privatePem;
  final String publicLine;
}

/// A new ed25519 key in OpenSSH format, from a secure random seed.
GeneratedKey generateEd25519({String comment = 'pocketrig', Random? random}) {
  final r = random ?? Random.secure();
  final seed = Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
  final signing = nacl.SigningKey.fromSeed(seed);
  final pub = Uint8List.fromList(signing.verifyKey.asTypedList);
  // OpenSSH stores ed25519 private keys as seed ‖ public key (64 bytes).
  final priv = Uint8List.fromList(signing.asTypedList);
  final pair = OpenSSHEd25519KeyPair(pub, priv, comment);
  return GeneratedKey(pair.toPem(), publicKeyLine(pair, comment));
}

/// `ssh-ed25519 AAAA… comment` for any key pair dartssh2 can read.
String publicKeyLine(SSHKeyPair pair, [String comment = 'pocketrig']) =>
    '${pair.type} ${base64.encode(pair.toPublicKey().encode())} $comment';

/// The public line for a saved private key, or null if it can't be read.
String? publicKeyFromPem(String pem, {String? passphrase, String comment = 'pocketrig'}) {
  try {
    final pairs = SSHKeyPair.fromPem(pem.trim(), passphrase);
    return pairs.isEmpty ? null : publicKeyLine(pairs.first, comment);
  } catch (_) {
    return null;
  }
}

/// "ed25519 · SHA256:k3J…9Qx": the key's type and OpenSSH fingerprint,
/// shortened for the key box (the full one is in [publicKeyFromPem]'s line).
String? keySummary(String pem, {String? passphrase}) {
  try {
    final pairs = SSHKeyPair.fromPem(pem.trim(), passphrase);
    if (pairs.isEmpty) return null;
    final pair = pairs.first;
    final fp = base64.encode(sha256.convert(pair.toPublicKey().encode()).bytes).replaceAll('=', '');
    final type = pair.type.replaceFirst('ssh-', '').replaceFirst('ecdsa-sha2-', 'ecdsa ');
    return '$type · SHA256:${fp.substring(0, 3)}…${fp.substring(fp.length - 3)}';
  } catch (_) {
    return null;
  }
}
