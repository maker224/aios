//! AIoS relay server (Rust).
//!
//! Drop-in replacement for the Dart relay in `server/relay` — same wire
//! protocol, same dashboard. A dumb forwarder:
//! * Devices register with a group id and a device id.
//! * Devices in the same group see each other (presence).
//! * Devices route JSON envelopes to each other.
//!
//! The relay never sees plaintext data: all envelopes are end-to-end
//! encrypted with per-pair keys negotiated during device pairing.
//!
//! Protocol (JSON over WebSocket at /ws):
//!   -> {op: register, g, id, name, platform, pub}
//!   <- {op: registered}
//!   <- {op: presence, peers: [{id, name, platform, pub}]}
//!   -> {op: route, to, e: envelope}   <- {op: route, from, e: envelope}
//!   -> {op: ping}                     <- {op: pong}

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, Notify};

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

struct Conn {
    group: String,
    id: String,
    name: String,
    platform: String,
    pub_key: Option<String>,
    sender: mpsc::UnboundedSender<String>,
    shutdown: Arc<Notify>,
    last_ping: AtomicU64, // unix seconds
    routed: AtomicU64,
}

struct AppState {
    groups: Mutex<HashMap<String, HashMap<String, Arc<Conn>>>>,
    total_routed: AtomicU64,
    total_registered: AtomicU64,
    started_at: Instant,
}

impl AppState {
    fn new() -> Self {
        Self {
            groups: Mutex::new(HashMap::new()),
            total_routed: AtomicU64::new(0),
            total_registered: AtomicU64::new(0),
            started_at: Instant::now(),
        }
    }
}

type Shared = Arc<AppState>;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080);
    let state: Shared = Arc::new(AppState::new());

    // Heartbeat sweep: drop clients that stopped pinging.
    {
        let state = state.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(30));
            loop {
                interval.tick().await;
                sweep(&state);
            }
        });
    }

    let app = router(state);
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .expect("failed to bind");
    println!(
        "AIoS relay (Rust) listening on port {} (ws://0.0.0.0:{}/ws)",
        port, port
    );
    axum::serve(listener, app).await.expect("server error");
}

fn router(state: Shared) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/api/state", get(api_state))
        .route("/dashboard", get(dashboard))
        .route("/", get(root))
        .route("/ws", get(ws_handler))
        .with_state(state)
}

async fn health(State(state): State<Shared>) -> impl IntoResponse {
    let groups = state.groups.lock().unwrap().len();
    axum::Json(json!({"status": "ok", "groups": groups}))
}

async fn root(State(state): State<Shared>) -> impl IntoResponse {
    let groups = state.groups.lock().unwrap().len();
    format!(
        "AIoS relay v1 (Rust)\nWebSocket endpoint: /ws\nDashboard: /dashboard\nGroups connected: {}",
        groups
    )
}

async fn dashboard() -> Html<&'static str> {
    Html(DASHBOARD_HTML)
}

async fn api_state(State(state): State<Shared>) -> impl IntoResponse {
    let uptime = state.started_at.elapsed().as_secs();
    let now = now_secs();
    let groups = state.groups.lock().unwrap();
    let connections: usize = groups.values().map(|g| g.len()).sum();
    let group_list: Vec<Value> = groups
        .iter()
        .map(|(gid, devices)| {
            json!({
                "groupId": gid,
                "devices": devices.values().map(|c| json!({
                    "id": c.id,
                    "name": c.name,
                    "platform": c.platform,
                    "online": now.saturating_sub(c.last_ping.load(Ordering::Relaxed)) < 90,
                    "lastSeenSecondsAgo": now.saturating_sub(c.last_ping.load(Ordering::Relaxed)),
                    "routed": c.routed.load(Ordering::Relaxed),
                })).collect::<Vec<_>>(),
            })
        })
        .collect();
    axum::Json(json!({
        "status": "ok",
        "uptimeSeconds": uptime,
        "groups": groups.len(),
        "connections": connections,
        "messagesRouted": state.total_routed.load(Ordering::Relaxed),
        "registrations": state.total_registered.load(Ordering::Relaxed),
        "groupList": group_list,
    }))
}

// ---------------------------------------------------------------------------
// WebSocket connections
// ---------------------------------------------------------------------------

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<Shared>) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: Shared) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();

    // Writer task: forwards outgoing messages; stops on shutdown signal.
    let shutdown = Arc::new(Notify::new());
    let writer_shutdown = shutdown.clone();
    let write_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = writer_shutdown.notified() => break,
                msg = rx.recv() => {
                    match msg {
                        Some(m) => {
                            if sink.send(Message::Text(m.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
            }
        }
    });

    let mut conn: Option<Arc<Conn>> = None;

    while let Some(Ok(msg)) = stream.next().await {
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Close(_) => break,
            _ => continue,
        };
        let v: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => continue,
        };

        match v.get("op").and_then(|o| o.as_str()) {
            Some("register") => {
                let g = v.get("g").and_then(|x| x.as_str()).unwrap_or("").to_string();
                let id = v.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
                if g.is_empty() || id.is_empty() {
                    continue;
                }
                let c = Arc::new(Conn {
                    group: g.clone(),
                    id: id.clone(),
                    name: v
                        .get("name")
                        .and_then(|x| x.as_str())
                        .unwrap_or("Unknown")
                        .to_string(),
                    platform: v.get("platform").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                    pub_key: v.get("pub").and_then(|x| x.as_str()).map(String::from),
                    sender: tx.clone(),
                    shutdown: shutdown.clone(),
                    last_ping: AtomicU64::new(now_secs()),
                    routed: AtomicU64::new(0),
                });
                {
                    let mut groups = state.groups.lock().unwrap();
                    let group = groups.entry(g.clone()).or_default();
                    if let Some(old) = group.insert(id.clone(), c.clone()) {
                        old.shutdown.notify_one(); // kick the previous session
                    }
                    state.total_registered.fetch_add(1, Ordering::Relaxed);
                }
                conn = Some(c.clone());
                let _ = c.sender.send(json!({"op": "registered"}).to_string());
                broadcast_presence(&state, &g);
            }
            Some("route") => {
                if let Some(c) = &conn {
                    let to = v.get("to").and_then(|x| x.as_str()).unwrap_or("").to_string();
                    let env = v.get("e").cloned().unwrap_or(Value::Null);
                    let target = {
                        let groups = state.groups.lock().unwrap();
                        groups.get(&c.group).and_then(|g| g.get(&to)).cloned()
                    };
                    if let Some(t) = target {
                        let msg = json!({"op": "route", "from": c.id, "e": env});
                        if t.sender.send(msg.to_string()).is_ok() {
                            c.routed.fetch_add(1, Ordering::Relaxed);
                            t.routed.fetch_add(1, Ordering::Relaxed);
                            state.total_routed.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                }
            }
            Some("ping") => {
                if let Some(c) = &conn {
                    c.last_ping.store(now_secs(), Ordering::Relaxed);
                    let _ = c.sender.send(json!({"op": "pong"}).to_string());
                }
            }
            _ => {}
        }
    }

    // Cleanup: remove this connection (if it is still the registered one).
    if let Some(c) = conn {
        let mut groups = state.groups.lock().unwrap();
        let mut gone = false;
        if let Some(group) = groups.get_mut(&c.group) {
            if let Some(existing) = group.get(&c.id) {
                if Arc::ptr_eq(existing, &c) {
                    group.remove(&c.id);
                    gone = true;
                }
            }
            if group.is_empty() {
                groups.remove(&c.group);
                gone = true;
            }
        }
        drop(groups);
        if gone {
            broadcast_presence(&state, &c.group);
        }
    }
    write_task.abort();
}

/// Removes connections whose last ping is older than 90 seconds.
fn sweep(state: &Shared) {
    let now = now_secs();
    let mut affected = Vec::new();
    {
        let mut groups = state.groups.lock().unwrap();
        let empty: Vec<String> = groups
            .iter_mut()
            .filter_map(|(gid, devices)| {
                let mut removed = false;
                devices.retain(|_, c| {
                    let stale = now.saturating_sub(c.last_ping.load(Ordering::Relaxed)) > 90;
                    if stale {
                        c.shutdown.notify_one();
                        removed = true;
                    }
                    !stale
                });
                if removed {
                    affected.push(gid.clone());
                }
                devices.is_empty().then_some(gid.clone())
            })
            .collect();
        for gid in empty {
            groups.remove(&gid);
        }
    }
    for gid in affected {
        broadcast_presence(state, &gid);
    }
}

fn broadcast_presence(state: &Shared, group_id: &str) {
    let payload = {
        let groups = state.groups.lock().unwrap();
        let Some(group) = groups.get(group_id) else {
            return;
        };
        let peers: Vec<Value> = group
            .values()
            .map(|c| {
                json!({
                    "id": c.id,
                    "name": c.name,
                    "platform": c.platform,
                    "pub": c.pub_key,
                })
            })
            .collect();
        json!({"op": "presence", "peers": peers}).to_string()
    };
    let groups = state.groups.lock().unwrap();
    if let Some(group) = groups.get(group_id) {
        for c in group.values() {
            let _ = c.sender.send(payload.clone());
        }
    }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

const DASHBOARD_HTML: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AIoS Relay</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px 20px;
    background: #0f1117; color: #e6e8ee;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  .wrap { max-width: 860px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub { color: #8b91a3; font-size: 13px; margin-bottom: 24px; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 28px; }
  .card { background: #171a23; border: 1px solid #262b38; border-radius: 12px; padding: 14px 16px; }
  .card .num { font-size: 26px; font-weight: 700; }
  .card .lbl { color: #8b91a3; font-size: 12px; margin-top: 2px; }
  .group { background: #171a23; border: 1px solid #262b38; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
  .group h2 { font-size: 15px; margin: 0 0 12px; word-break: break-all; }
  .group h2 .cnt { color: #8b91a3; font-weight: 400; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; color: #8b91a3; font-weight: 500; padding: 6px 8px; border-bottom: 1px solid #262b38; }
  td { padding: 8px; border-bottom: 1px solid #1d2130; }
  tr:last-child td { border-bottom: none; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
  .on { background: #34d399; } .off { background: #6b7280; }
  .platform { color: #8b91a3; }
  .empty { color: #8b91a3; text-align: center; padding: 40px 0; }
  .foot { color: #565c6e; font-size: 11px; text-align: center; margin-top: 24px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>AIoS Relay <span class="sub" style="margin-left:8px">(Rust)</span></h1>
  <div class="sub">Live status — updates every 2 seconds</div>
  <div class="cards">
    <div class="card"><div class="num" id="uptime">–</div><div class="lbl">Uptime</div></div>
    <div class="card"><div class="num" id="groups">–</div><div class="lbl">Sync groups</div></div>
    <div class="card"><div class="num" id="conns">–</div><div class="lbl">Connected devices</div></div>
    <div class="card"><div class="num" id="msgs">–</div><div class="lbl">Envelopes routed</div></div>
  </div>
  <div id="groupsArea"><div class="empty">Loading…</div></div>
  <div class="foot">All payloads are end-to-end encrypted — the relay forwards ciphertext only.</div>
</div>
<script>
function fmtUptime(s) {
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
  if (s < 86400) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
  return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h";
}
function fmtAgo(s) {
  if (s < 5) return "now";
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  return Math.floor(s / 3600) + "h ago";
}
const PLATFORM = { ios: "iPhone/iPad", macos: "Mac", android: "Android", windows: "Windows" };
async function refresh() {
  try {
    const r = await fetch("/api/state");
    const s = await r.json();
    document.getElementById("uptime").textContent = fmtUptime(s.uptimeSeconds);
    document.getElementById("groups").textContent = s.groups;
    document.getElementById("conns").textContent = s.connections;
    document.getElementById("msgs").textContent = s.messagesRouted;
    const area = document.getElementById("groupsArea");
    if (!s.groupList.length) {
      area.innerHTML = '<div class="empty">No devices connected yet.<br>Point the AIoS app at this relay to see them here.</div>';
      return;
    }
    area.innerHTML = s.groupList.map(g => {
      const rows = g.devices.map(d => {
        const dot = d.online ? '<span class="dot on"></span>' : '<span class="dot off"></span>';
        return '<tr><td>' + dot + esc(d.name) + '</td><td class="platform">' + (PLATFORM[d.platform] || d.platform || "–") + '</td>' +
               '<td class="platform">' + esc(d.id.slice(0, 8)) + '</td><td>' + fmtAgo(d.lastSeenSecondsAgo) + '</td><td>' + d.routed + '</td></tr>';
      }).join("");
      return '<div class="group"><h2>Group <span class="cnt">(' + g.devices.length + ' devices)</span> ' + esc(g.groupId) + '</h2>' +
             '<table><tr><th>Device</th><th>Platform</th><th>ID</th><th>Last seen</th><th>Routed</th></tr>' + rows + '</table></div>';
    }).join("");
  } catch (e) { document.getElementById("groupsArea").innerHTML = '<div class="empty">Relay unreachable</div>'; }
}
function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }
refresh();
setInterval(refresh, 2000);
</script>
</body>
</html>
"#;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as WsMessage;

    type WsClient = tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >;

    async fn recv_json(stream: &mut futures_util::stream::SplitStream<WsClient>) -> Value {
        loop {
            let msg = stream.next().await.expect("stream closed").unwrap();
            if let WsMessage::Text(t) = msg {
                return serde_json::from_str(&t.to_string()).unwrap();
            }
        }
    }

    #[tokio::test]
    async fn register_presence_and_route() {
        // Bind an ephemeral port, then start the app router on it.
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let state: Shared = Arc::new(AppState::new());
        let app = router(state.clone());
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });

        let url = format!("ws://127.0.0.1:{}/ws", port);
        let (a, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
        let (b, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

        let (mut a_sink, mut a_stream) = a.split();
        let (mut b_sink, mut b_stream) = b.split();

        a_sink
            .send(WsMessage::Text(
                json!({
                    "op": "register", "g": "test-group", "id": "device-A",
                    "name": "iPhone", "platform": "ios", "pub": "pubA"
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();
        b_sink
            .send(WsMessage::Text(
                json!({
                    "op": "register", "g": "test-group", "id": "device-B",
                    "name": "Windows PC", "platform": "windows", "pub": "pubB"
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();

        // Wait for presence on A that includes both devices, then presence on B.
        let mut a_presence: Option<Value> = None;
        for _ in 0..4 {
            let v = tokio::time::timeout(Duration::from_secs(2), recv_json(&mut a_stream))
                .await
                .unwrap();
            if v["op"] == "presence" {
                let has_both = v["peers"]
                    .as_array()
                    .map(|arr| {
                        let ids: Vec<&str> = arr
                            .iter()
                            .filter_map(|p| p["id"].as_str())
                            .collect();
                        ids.contains(&"device-A") && ids.contains(&"device-B")
                    })
                    .unwrap_or(false);
                if has_both {
                    a_presence = Some(v);
                    break;
                }
            }
        }
        assert!(
            a_presence.is_some(),
            "A never saw presence with both devices"
        );

        let mut b_presence: Option<Value> = None;
        for _ in 0..4 {
            let v = tokio::time::timeout(Duration::from_secs(2), recv_json(&mut b_stream))
                .await
                .unwrap();
            if v["op"] == "presence" {
                b_presence = Some(v);
                break;
            }
        }
        assert!(b_presence.is_some(), "B never got presence");

        // Route an envelope from A to B.
        a_sink
            .send(WsMessage::Text(
                json!({
                    "op": "route", "to": "device-B", "e": {"t": "ping"}
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();

        let routed = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let v = recv_json(&mut b_stream).await;
                if v["op"] == "route" {
                    return v;
                }
            }
        })
        .await
        .expect("route message never arrived");
        assert_eq!(routed["from"], "device-A");
        assert_eq!(routed["e"]["t"], "ping");

        let _ = a_sink.send(WsMessage::Close(None)).await;
        let _ = b_sink.send(WsMessage::Close(None)).await;
    }
}
