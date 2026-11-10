import 'dart:convert';
import 'dart:typed_data';

import 'package:aios/core/crypto/keys.dart';
import 'package:cryptography/cryptography.dart';

/// Wire message envelope.
///
/// Plaintext (pairing only):
/// ```json
/// { "v": 1, "t": "pairing_init", "f": "<deviceId>", "ts": 123, "p": {...} }
/// ```
///
/// Encrypted (after pairing):
/// ```json
/// { "v": 1, "t": "records", "f": "<deviceId>", "ts": 123,
///   "e": "<base64(nonce|ciphertext|mac)>" }
/// ```
class Messages {
  Messages._();

  static Future<Map<String, dynamic>> buildMessage(
    String type,
    String from,
    Map<String, dynamic> payload, {
    SecretKey? key,
  }) async {
    final base = <String, dynamic>{
      'v': 1,
      't': type,
      'f': from,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    if (key == null) {
      base['p'] = payload;
    } else {
      base['e'] = await encryptPayload(jsonEncode(payload), key);
    }
    return base;
  }

  /// Decodes a raw JSON string into `{ 't': type, 'f': from, 'p': payload }`.
  ///
  /// Throws if the message is malformed or decryption fails.
  static Future<Map<String, dynamic>> decodeMessage(String raw,
      {SecretKey? key}) async {
    return decodeEnvelope(jsonDecode(raw) as Map<String, dynamic>, key: key);
  }

  /// Same as [decodeMessage] but takes an already-parsed envelope.
  static Future<Map<String, dynamic>> decodeEnvelope(
      Map<String, dynamic> json,
      {SecretKey? key}) async {
    final type = json['t'] as String? ?? '';
    final from = json['f'] as String? ?? '';
    Map<String, dynamic> payload;
    if (json.containsKey('e')) {
      if (key == null) {
        throw const FormatException('encrypted message without key');
      }
      final clear = await decryptPayload(json['e'] as String, key);
      payload = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } else {
      payload = (json['p'] as Map?)?.cast<String, dynamic>() ?? {};
    }
    return {'t': type, 'f': from, 'p': payload};
  }

  static Future<String> encryptPayload(String plain, SecretKey key) async {
    final bytes = await CryptoKeys.encryptBytes(
        Uint8List.fromList(utf8.encode(plain)), key);
    return base64Encode(bytes);
  }

  static Future<Uint8List> decryptPayload(String b64, SecretKey key) async {
    return CryptoKeys.decryptBytes(base64Decode(b64), key);
  }
}
