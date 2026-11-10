# AIoS — All-in-One Sync

Sync **files, photos, contacts, calendars, clipboard, and notes** between
**iPhone / iPad (iOS), Mac (macOS), Android, and Windows** — with one Flutter
codebase.

- 📡 **Local Wi-Fi P2P first** — devices on the same network sync directly,
  encrypted end-to-end. No account, no cloud.
- ☁️ **Cloud relay fallback** — an optional self-hosted relay (included in
  `server/relay/`) lets devices sync across the internet.
- 🔐 **End-to-end encrypted** — X25519 key exchange with a 6-digit pairing
  code (verifies no man-in-the-middle), AES-256-GCM for all traffic. The
  relay only forwards ciphertext.

---

## Feature matrix

| Feature                    | iOS | macOS | Android | Windows |
| -------------------------- | :-: | :---: | :-----: | :-----: |
| Files & photos (send/recv) | ✅  | ✅    | ✅      | ✅      |
| Contacts (two-way)         | ✅  | ✅    | ✅      | ❌ ¹    |
| Calendar (two-way)         | ✅  | ❌ ²  | ✅      | ❌ ²    |
| Clipboard (auto)           | ✅  | ✅    | ✅      | ✅      |
| Notes                      | ✅  | ✅    | ✅      | ✅      |
| Local network sync         | ✅  | ✅    | ✅      | ✅      |
| Relay sync                 | ✅  | ✅    | ✅      | ✅      |

¹ `flutter_contacts` has no Windows implementation yet.
² `device_calendar` supports only Android and iOS.

> **v1 limitation:** the app syncs while it is open (foreground). True
> background sync on iOS/Android requires background tasks that are not part
> of this first version.

---

## Quick start

### 1. Install Flutter

Follow https://docs.flutter.dev/get-started/install and run `flutter doctor`
until your target platforms show no errors (Xcode for iOS/macOS, Android
Studio for Android, Visual Studio for Windows).

### 2. Scaffold + run

```bash
# From this directory (AIoS/):
chmod +x scripts/setup.sh
./scripts/setup.sh

flutter run -d macos      # or -d ios / -d android / -d windows
```

`setup.sh` runs `flutter create` (generates the platform scaffolding without
touching existing files), patches platform permissions via
`scripts/apply_permissions.py`, and fetches packages.

### 3. Pair devices

1. Run the app on two devices on the **same Wi-Fi**.
2. Open **Devices** → **Scan network** (or **Connect manually** with the
   other device's IP:47631).
3. A 6-digit code appears on **both** devices — confirm it matches, then
   accept on both. Done. They are now paired and start syncing.

Unpaired devices in your sync group (via the relay) also show up under
**Devices → Sync group**.

### 3.5 First-run options & the Options screen

On first launch the app walks you through an **onboarding wizard** where you
choose:

- **What to sync** — Files & photos, Contacts, Calendar, Clipboard, Notes
  (each can be toggled independently; disabled types are neither sent nor
  accepted, and the engine respects this end-to-end).
- **How devices connect** — *Wi-Fi only* (most private) or *Wi-Fi + relay*
  (adds sync from anywhere via your relay URL + sync group id).

Everything chosen during onboarding can be changed later in the
**Options** screen, which groups all choices: *What to sync*, *How devices
connect* (including relay URL, group id and local sync port), *Privacy*
(accept incoming files), *This device*, and storage/about info.

### 4. Optional: cloud relay

```bash
cd server/relay
dart pub get
dart run bin/server.dart        # listens on :8080
# or: docker build -t aios-relay . && docker run -p 8080:8080 aios-relay
```

Deploy it anywhere that speaks TLS (Fly.io, Render, Railway, a VPS behind
nginx/caddy), then in the app go to **Settings → Relay URL** and enter
`wss://your-host/ws`, and set the same **Sync group id** on all your devices.
The relay can't read your data — it only forwards encrypted envelopes.

---

## Architecture

```
┌─────────────────────────────┐        ┌─────────────────────────────┐
│  Device A (e.g. iPhone)     │        │  Device B (e.g. Windows)    │
│                             │        │                             │
│  UI (Flutter)               │        │  UI (Flutter)               │
│   │                         │        │   │                         │
│  ConnectionManager          │        │  ConnectionManager          │
│   ├─ LocalServer  :47631    │◄──ws──►│   ├─ LocalServer  :47631    │
│   ├─ Discovery    :47632    │◄─udp──►│   ├─ Discovery    :47632    │
│   └─ RelayClient            │        │   └─ RelayClient            │
│   └──────────┐              │        │      └──────────┐           │
│  SyncEngine  │ (records)    │        │  SyncEngine     │ (records) │
│  Transfers   │ (files)      │        │  Transfers      │ (files)   │
│  Contacts/Calendar/Clipboard│        │  Contacts/…     │           │
└──────────────┼──────────────┘        └─────────────────┼───────────┘
               │                 e2e encrypted           │
               └─────────────► relay (dumb forwarder) ◄──┘
```

### Layers (`lib/`)

| Path                          | Purpose |
| ----------------------------- | ------- |
| `core/constants.dart`         | Wire protocol constants |
| `core/models.dart`            | Peer, SyncRecord, TransferItem, … |
| `core/crypto/keys.dart`       | X25519 + AES-256-GCM + pairing codes |
| `core/net/`                   | Discovery (UDP broadcast), local WS server, relay client, sessions |
| `core/net/connection_manager.dart` | Pairing state machine, routing, peer store |
| `core/sync/sync_engine.dart`  | Versioned records, LWW merge, per-peer outboxes |
| `core/transfers/transfer_manager.dart` | Chunked file streaming + SHA-256 verification |
| `core/features/`              | Platform adapters: contacts, calendar, clipboard, photos |
| `core/storage/app_store.dart` | Hive boxes + data directories |
| `state/`                      | Riverpod providers + settings |
| `ui/`                         | Screens and shared widgets |

### How sync works

- **Records** — contacts, calendar events, clipboard text and notes are
  versioned records `{id, type, deviceId, updatedAt, deleted, data}` with
  last-write-wins conflict resolution and tombstones. Each peer keeps a
  per-peer outbox; a change made on any device propagates to all others,
  even through intermediate devices.
- **Files/photos** — streamed in encrypted 192 KB chunks with per-chunk
  acks, verified with SHA-256, then moved into the *SyncedFiles* folder
  (organized by sending device).
- **Pairing** — both sides derive a shared secret with X25519, then display
  `123 456` (an HMAC of the secret). If the codes match on both screens, the
  devices store each other's keys and switch to encrypted sessions.
- **Discovery** — UDP broadcast (`AIOS_PING`/`AIOS_PONG`) on port 47632 plus
  manual IP entry. (mDNS can be added later; the abstraction point is
  `core/net/discovery.dart`.)

---

## Permissions (applied automatically by `scripts/apply_permissions.py`)

- **iOS**: local network, contacts, calendars, photo library, ATS local
  networking exception.
- **macOS**: local network + sandbox entitlements (incoming/outgoing network,
  contacts, calendars, photos, downloads).
- **Android**: internet, network state, Wi-Fi multicast lock, contacts,
  calendars, media images, and `usesCleartextTraffic` for LAN WebSockets.

---

## Deploying

### Relay server (for cross-network sync)

Two interchangeable implementations, same wire protocol:

| Implementation | Run it | Binary |
| -------------- | ------ | ------ |
| **Rust** (`server/relay-rust`) | `cargo run --release` | ~2 MB static, `cargo build --release` |
| **Dart** (`server/relay`) | `dart run bin/server.dart` | `dart compile exe` or the Dockerfile |

The Rust version is the recommended production target: axum + tokio,
tiny static binary, built and tested by CI (`cargo test` covers
register/presence/routing). Both serve the same `/ws`, `/health`,
`/api/state` and `/dashboard` endpoints.

| Host | How |
| ---- | --- |
| **Fly.io** | `cd server/relay-rust && flyctl launch && flyctl deploy` (Dockerfile included), or use the **Deploy relay to Fly.io** GitHub Action after adding a `FLY_API_TOKEN` secret |
| **Render** | New → Blueprint → this repo (config in `render.yaml`, free tier) |
| **Any VPS** | Run the compiled binary behind Caddy/nginx for TLS |
| **Home machine** | Run the binary on an always-on Mac/Pi + a Cloudflare tunnel |

Whatever host you pick, put the resulting `wss://…/ws` URL in the app under
**Options → How devices connect**, with the same **sync group id** on every
device.

### App builds

```bash
flutter build apk --release      # Android (also built by CI on every push)
flutter build macos --release    # macOS
flutter build windows --release  # Windows (must run on Windows)
flutter build ipa                # iOS (needs an Apple Developer account)
```

GitHub Actions (`.github/workflows/ci.yml`) runs `flutter analyze`, tests,
relay protocol tests + binary compile, and builds the Android APK as an
artifact on every push to `main`.

---

## Roadmap ideas

- [ ] mDNS (Bonjour/NSD) discovery alongside UDP broadcast
- [ ] Background sync (WorkManager / BGTaskScheduler)
- [ ] Photo auto-import into the gallery on iOS/Android
- [ ] File conflict handling (keep-both) and sync-on-edit for the synced folder
- [ ] QR-code pairing
- [ ] Share extension ("share to AIoS") on iOS/Android
- [ ] Relay auth + quotas
