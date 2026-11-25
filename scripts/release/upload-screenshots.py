#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Upload App Store screenshots for one version localization through the App Store Connect API.

  upload-screenshots.py <localization-id> <display-type>=<folder> [...]          print the plan, send nothing
  upload-screenshots.py --send <localization-id> <display-type>=<folder> [...]   create the sets and upload

Display types are Apple's ScreenshotDisplayType values, e.g. APP_IPHONE_67, APP_IPAD_PRO_3GEN_129,
APP_WATCH_SERIES_10. Files go up in name order. Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
A display type that already has a set is refused: delete the set in App Store Connect first.
"""
import base64, hashlib, json, os, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"
# Portrait sizes Apple accepts per display type (screenshot specifications page, read 2026-11-10); landscape is the swap.
SIZES = {
    "APP_IPHONE_67": {(1260, 2736), (1290, 2796), (1320, 2868)},
    "APP_IPAD_PRO_3GEN_129": {(2064, 2752), (2048, 2732)},
    "APP_WATCH_SERIES_10": {(416, 496)},
    "APP_WATCH_ULTRA": {(422, 514), (410, 502)},
}


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def token():
    now = int(time.time())
    head = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    body = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signed = b64(json.dumps(head).encode()) + b"." + b64(json.dumps(body).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=signed, capture_output=True, check=True).stdout
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)  # DER signature to the raw r||s form JWT wants
    r = der[i + 2:i + 2 + der[i + 1]]
    j = i + 2 + der[i + 1]
    s = der[j + 2:j + 2 + der[j + 1]]
    raw = r.lstrip(b"\x00").rjust(32, b"\x00") + s.lstrip(b"\x00").rjust(32, b"\x00")
    return (signed + b"." + b64(raw)).decode()


def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path}: {error.code} {error.read().decode()[:800]}")


def size(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
                         capture_output=True, text=True, check=True).stdout
    values = dict(line.split(": ") for line in out.strip().split("\n")[1:])
    return int(values["  pixelWidth"]), int(values["  pixelHeight"]), values["  hasAlpha"]


def main():
    args = sys.argv[1:]
    send = args[:1] == ["--send"]
    if send:
        args = args[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    localization, plan = args[0], []
    for pair in args[1:]:
        display, folder = pair.split("=", 1)
        if display not in SIZES:
            sys.exit(f"unknown display type {display}; known: {', '.join(SIZES)}")
        files = sorted(Path(folder).glob("*.png"))
        if not 1 <= len(files) <= 10:
            sys.exit(f"{folder}: {len(files)} screenshots, Apple takes 1 to 10")
        for file in files:
            width, height, alpha = size(file)
            if (min(width, height), max(width, height)) not in SIZES[display] or alpha != "no":
                sys.exit(f"{file}: {width}x{height}, alpha {alpha}: not accepted for {display}")
            print(f"{display}  {file.name}  {width}x{height}")
        plan.append((display, files))
    if not send:
        print("plan only; nothing sent (use --send)")
        return
    existing = call("GET", f"/v1/appStoreVersionLocalizations/{localization}/appScreenshotSets")
    taken = {item["attributes"]["screenshotDisplayType"] for item in existing.get("data", [])}
    for display, files in plan:
        if display in taken:
            sys.exit(f"{display} already has a screenshot set; nothing more sent")
        made = call("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": localization}}}}})
        set_id = made["data"]["id"]
        for file in files:
            content = file.read_bytes()
            shot = call("POST", "/v1/appScreenshots", {"data": {
                "type": "appScreenshots", "attributes": {"fileName": file.name, "fileSize": len(content)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
            for part in shot["attributes"]["uploadOperations"]:
                headers = {header["name"]: header["value"] for header in part["requestHeaders"]}
                chunk = content[part["offset"]:part["offset"] + part["length"]]
                with urllib.request.urlopen(urllib.request.Request(
                        part["url"], data=chunk, method=part["method"], headers=headers), timeout=300):
                    pass
            call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {
                "type": "appScreenshots", "id": shot["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(content).hexdigest()}}})
            print(f"uploaded {display} {file.name}")


if __name__ == "__main__":
    main()
