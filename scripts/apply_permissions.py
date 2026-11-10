#!/usr/bin/env python3
"""Patches generated platform files with the permissions AIoS needs.

Run AFTER `flutter create` (see scripts/setup.sh). Idempotent.
"""
import os
import plistlib
from xml.etree import ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def update_plist(path, keys):
    if not os.path.exists(path):
        print(f"  skip {path} (not found)")
        return
    with open(path, "rb") as f:
        data = plistlib.load(f)
    changed = False
    for k, v in keys.items():
        if k not in data:
            data[k] = v
            changed = True
    if changed:
        with open(path, "wb") as f:
            plistlib.dump(data, f)
        print(f"  updated {path}")


def update_android_manifest(path):
    if not os.path.exists(path):
        print(f"  skip {path} (not found)")
        return
    ns = "http://schemas.android.com/apk/res/android"
    ET.register_namespace("android", ns)

    def a(name):
        return f"{{{ns}}}{name}"

    tree = ET.parse(path)
    root = tree.getroot()

    # (permission name, extra attributes)
    perms = [
        ("android.permission.INTERNET", {}),
        ("android.permission.ACCESS_NETWORK_STATE", {}),
        ("android.permission.ACCESS_WIFI_STATE", {}),
        ("android.permission.CHANGE_WIFI_MULTICAST_STATE", {}),
        ("android.permission.READ_CONTACTS", {}),
        ("android.permission.WRITE_CONTACTS", {}),
        ("android.permission.READ_CALENDAR", {}),
        ("android.permission.WRITE_CALENDAR", {}),
        ("android.permission.READ_MEDIA_IMAGES", {}),
        ("android.permission.READ_EXTERNAL_STORAGE", {a("maxSdkVersion"): "32"}),
    ]
    existing = {p.get(a("name")) for p in root.findall("uses-permission")}
    changed = False
    for name, attrs in perms:
        if name in existing:
            continue
        el = ET.Element("uses-permission")
        el.set(a("name"), name)
        for k, v in attrs.items():
            el.set(k, v)
        # Insert before <application> (schema order).
        app = root.find("application")
        if app is not None:
            idx = list(root).index(app)
        else:
            idx = len(list(root))
        root.insert(idx, el)
        changed = True

    app = root.find("application")
    if app is not None and a("usesCleartextTraffic") not in app.attrib:
        # Allow ws:// to LAN IPs (direct device-to-device sync).
        app.set(a("usesCleartextTraffic"), "true")
        changed = True

    if changed:
        tree.write(path, encoding="utf-8", xml_declaration=True)
        print(f"  updated {path}")


ios_keys = {
    "NSLocalNetworkUsageDescription":
        "AIoS connects to your other devices on the local network to sync "
        "files, photos, contacts, calendars, clipboard and notes.",
    "NSContactsUsageDescription":
        "AIoS syncs your contacts with your other devices.",
    "NSCalendarsUsageDescription":
        "AIoS syncs events from the AIoS Synced calendar with your other "
        "devices.",
    "NSPhotoLibraryUsageDescription":
        "AIoS lets you select photos to send to your other devices.",
    "NSPhotoLibraryAddUsageDescription":
        "AIoS stores photos received from your other devices.",
    "NSAppTransportSecurity": {
        "NSAllowsLocalNetworking": True,
    },
}

macos_keys = dict(ios_keys)
macos_keys.pop("NSPhotoLibraryAddUsageDescription", None)

macos_entitlements = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.server": True,
    "com.apple.security.network.client": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.files.downloads.read-write": True,
    "com.apple.security.personal-information.contacts": True,
    "com.apple.security.personal-information.calendars": True,
    "com.apple.security.personal-information.photos-library": True,
}

print("Applying permissions:")
update_plist(os.path.join(ROOT, "ios", "Runner", "Info.plist"), ios_keys)
update_plist(os.path.join(ROOT, "macos", "Runner", "Info.plist"), macos_keys)
update_plist(
    os.path.join(ROOT, "macos", "Runner", "DebugProfile.entitlements"),
    macos_entitlements,
)
update_plist(
    os.path.join(ROOT, "macos", "Runner", "Release.entitlements"),
    macos_entitlements,
)
update_android_manifest(
    os.path.join(
        ROOT, "android", "app", "src", "main", "AndroidManifest.xml"
    )
)
print("Done.")
