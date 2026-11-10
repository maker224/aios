import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:aios/core/constants.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hash;

/// Local key material and pairing helpers.
///
/// * Each device owns one static X25519 key pair.
/// * Pairing derives a per-pair shared secret (ECDH). That static secret is
///   stored and used as an AES-256-GCM key for all messages with that peer.
/// * Both sides display a 6-digit verification code derived from the shared
///   secret, so the user can detect a man in the middle.
class CryptoKeys {
  CryptoKeys._();

  static SimpleKeyPair? _pair;

  static SimpleKeyPair get pair =>
      _pair ?? (throw StateError('CryptoKeys.init not called'));

  static void init(Uint8List pub, Uint8List priv) {
    _pair = SimpleKeyPairData(
      priv,
      type: KeyPairType.x25519,
      publicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
    );
  }

  /// Generates a fresh X25519 key pair. Returns (publicKey, privateKey).
  static Future<(Uint8List, Uint8List)> generate() async {
    final keyPair = await X25519().newKeyPair();
    final pub = await keyPair.extractPublicKey();
    final priv = await keyPair.extractPrivateKeyBytes();
    return (Uint8List.fromList(pub.bytes), Uint8List.fromList(priv));
  }

  static Future<Uint8List> myPublicKey() async {
    final pub = await pair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Derives the shared secret with a remote device.
  static Future<SecretKey> sharedSecretWith(Uint8List remotePublicKey) async {
    final secret = await X25519().sharedSecretKey(
      keyPair: pair,
      remotePublicKey:
          SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
    );
    return secret;
  }

  /// 6-digit pairing code, formatted as `123 456`.
  static Future<String> pairingCode(
      SecretKey secret, String idA, String idB) async {
    final secretBytes = await secret.extractBytes();
    final ids = [idA, idB]..sort();
    final input = utf8.encode(
        '${K.pairingPrefix}${ids[0]}|${ids[1]}');
    final digest = hash.Hmac(hash.sha256, secretBytes).convert(input).bytes;
    final digits = digest.take(6).map((b) => b % 10).join();
    return '${digits.substring(0, 3)} ${digits.substring(3)}';
  }

  /// Stored shared secret for an already-paired peer.
  static SecretKey storedSecret(List<int> bytes) =>
      SecretKey(Uint8List.fromList(bytes));

  // ---- Message encryption helpers (nonce || ciphertext || mac) ----

  static Uint8List randomBytes(int n) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }

  static Future<Uint8List> encryptBytes(Uint8List plain, SecretKey key) async {
    final aes = AesGcm.with256bits();
    final nonce = randomBytes(12);
    final box = await aes.encrypt(plain, secretKey: key, nonce: nonce);
    final out = BytesBuilder(copy: false)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  static Future<Uint8List> decryptBytes(Uint8List data, SecretKey key) async {
    final aes = AesGcm.with256bits();
    final nonce = Uint8List.sublistView(data, 0, 12);
    final mac = Uint8List.sublistView(data, data.length - 16);
    final cipherText = Uint8List.sublistView(data, 12, data.length - 16);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    return Uint8List.fromList(await aes.decrypt(box, secretKey: key));
  }
}
