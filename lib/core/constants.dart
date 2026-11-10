/// Global constants for the AIoS app and its wire protocol.
library;

class K {
  K._();

  static const String appName = 'AIoS';
  static const String appVersion = '0.1.0';

  /// Wire protocol version. Bump when the message format changes.
  static const int protocolVersion = 1;

  /// TCP port for the local WebSocket server (device-to-device sync).
  static const int defaultPort = 47631;

  /// UDP port used for broadcast discovery (AIOS_PING / AIOS_PONG).
  static const int discoveryPort = 47632;

  /// Default cloud relay endpoint. Replace with your own relay deployment.
  static const String defaultRelayUrl = 'wss://relay.example.com/ws';

  /// Sync group id. Devices that share a group id can see each other
  /// through the relay.
  static const String defaultGroupId = 'default-group';

  /// Size of one file-transfer chunk (before base64 + encryption).
  static const int chunkSize = 192 * 1024;

  /// Where received files are stored, inside the app data directory.
  static const String syncedFolderName = 'SyncedFiles';

  /// Pairing code derivation prefix (HMAC input).
  static const String pairingPrefix = 'aios-pairing-v1|';

  /// Relay protocol op codes.
  static const String relayOpRegister = 'register';
  static const String relayOpRegistered = 'registered';
  static const String relayOpPresence = 'presence';
  static const String relayOpRoute = 'route';
  static const String relayOpPing = 'ping';
  static const String relayOpPong = 'pong';

  /// Envelope message types (inside the encrypted channel).
  static const String msgHello = 'hello';
  static const String msgPairingInit = 'pairing_init';
  static const String msgPairingConfirm = 'pairing_confirm';
  static const String msgPairingReject = 'pairing_reject';
  static const String msgRecords = 'records';
  static const String msgAcks = 'acks';
  static const String msgRecordsDone = 'records_done';
  static const String msgFileOffer = 'file_offer';
  static const String msgFileOfferAck = 'file_offer_ack';
  static const String msgFileChunk = 'file_chunk';
  static const String msgFileAck = 'file_ack';
  static const String msgFileComplete = 'file_complete';
  static const String msgFileDone = 'file_done';
  static const String msgError = 'error';
  static const String msgPing = 'ping';
}
