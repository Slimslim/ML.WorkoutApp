#!/usr/bin/env python3
"""Checks the Rx Lab Supabase setup the same way the app uses it, with a throwaway test user.

Before running: Supabase dashboard > Authentication > Users > Add user > Create new user,
with an email and password of your choice and "Auto Confirm User" ticked.

    python3 tools/cloud_smoketest.py

It asks for that email and password (nothing is stored), then:
  1. signs in,
  2. uploads a small file to the user's folder (as the app does) and replaces it,
  3. records it in the uploads table (upsert, as the app does) and reads it back,
  4. checks it cannot write into another user's folder,
  5. deletes the file and calls delete_user, which removes the test user and its rows.
No other user's data is read or changed. Standard library only.
"""
import getpass
import json
import sys
import urllib.error
import urllib.request
import uuid

URL = "https://wgxhbifmjepjbqfqefmd.supabase.co"
KEY = "sb_publishable_dUVsP06QZtgM1wIqG87REw_T3Jl6ync"
BUCKET = "uploads"

passed = 0
failed = 0


def call(method, path, token=None, body=None, headers=None, raw=None):
    h = {"apikey": KEY, "Authorization": f"Bearer {token or KEY}"}
    data = None
    if raw is not None:
        data = raw
    elif body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            text = r.read().decode() or "null"
            return r.status, json.loads(text) if text.strip()[:1] in "[{n" else text
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


def main():
    email = input("Test user email: ").strip()
    password = getpass.getpass("Test user password (not shown): ")

    print("\n1. Sign in")
    status, session = call("POST", "/auth/v1/token?grant_type=password",
                           body={"email": email, "password": password})
    check("sign in", status == 200, f"{status} {session}")
    if status != 200:
        print("\nStopped: could not sign in. Was 'Auto Confirm User' ticked?")
        return 1
    token = session["access_token"]
    uid = session["user"]["id"]

    print("\n2. Upload a file to your own folder (and replace it)")
    path = f"{uid}/Lifts/smoketest/{uuid.uuid4()}.json"
    up = {"x-upsert": "true", "Content-Type": "application/json"}
    status, body = call("POST", f"/storage/v1/object/{BUCKET}/{path}", token, raw=b'{"test":1}', headers=up)
    check("upload", status == 200, f"{status} {body}")
    status, body = call("POST", f"/storage/v1/object/{BUCKET}/{path}", token, raw=b'{"test":2}', headers=up)
    check("replace (upsert)", status == 200, f"{status} {body}")
    status, body = call("GET", f"/storage/v1/object/authenticated/{BUCKET}/{path}", token)
    check("read it back", status == 200 and body == {"test": 2}, f"{status} {body}")

    print("\n3. Record it in the uploads table")
    row = {"user_id": uid, "path": path, "kind": "lifts", "bytes": 10,
           "file_modified_at": "2026-11-02T12:00:00Z"}
    merge = {"Prefer": "resolution=merge-duplicates,return=minimal"}
    status, body = call("POST", "/rest/v1/uploads?on_conflict=user_id,path", token, body=row, headers=merge)
    check("insert row", status in (200, 201, 204), f"{status} {body}")
    status, body = call("POST", "/rest/v1/uploads?on_conflict=user_id,path", token,
                        body=dict(row, bytes=11), headers=merge)
    check("update row (upsert)", status in (200, 201, 204), f"{status} {body}")
    status, body = call("GET", "/rest/v1/uploads?select=path,bytes", token)
    mine = [r for r in body if r.get("path") == path] if isinstance(body, list) else []
    check("read rows: only your own", status == 200 and len(mine) == 1 and mine[0]["bytes"] == 11
          and all(r["path"].startswith(uid) for r in body), f"{status} {body}")

    print("\n4. Cannot write into someone else's folder")
    other = f"{uuid.uuid4()}/Lifts/smoketest/x.json"
    status, body = call("POST", f"/storage/v1/object/{BUCKET}/{other}", token, raw=b"{}", headers=up)
    check("upload refused", status >= 400, f"{status} {body}")
    status, body = call("POST", "/rest/v1/uploads", token,
                        body=dict(row, user_id=str(uuid.uuid4()), path=other), headers=merge)
    check("row refused", status >= 400, f"{status} {body}")
    status, body = call("GET", f"/rest/v1/uploads?select=path", None)
    check("signed-out read refused", status >= 400 or body == [], f"{status} {body}")

    print("\n5. Delete account (as the app does)")
    status, body = call("DELETE", f"/storage/v1/object/{BUCKET}", token, body={"prefixes": [path]})
    check("delete file", status == 200, f"{status} {body}")
    status, body = call("POST", "/rest/v1/rpc/delete_user", token, body={})
    check("delete_user", status in (200, 204), f"{status} {body}")
    status, body = call("POST", "/auth/v1/token?grant_type=password",
                        body={"email": email, "password": password})
    check("test user is gone", status >= 400, f"{status}")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
