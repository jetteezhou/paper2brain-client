#!/usr/bin/env python3
"""Idea2do 的数据搬进 paper2brain 的随手记。

读 Idea2do 的数据库（~/Library/Application Support/Idea2do/workspace.sqlite，只读），转成它自己「导出为 JSON」的格式
（idea2do-export v1），再多带菜单导出里没有的：事件（matters）、事件归属（matterLinks）、原文的附件（先传上去）。
用这台 Mac 的 agent 口令发到服务器的 /api/bot/idea2do/import；按 Idea2do 的 id 收，再运行一次不会重复。

    python3 tools/idea2do_dump.py           # 只看有多少，不发
    python3 tools/idea2do_dump.py --send    # 传附件并导入
"""
import datetime as dt
import json
import os
import sqlite3
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path.home() / "Library/Application Support/Idea2do"
EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)  # Swift 的 Date 存的是从这一刻起的秒数
PRIORITY = {1: "high", 2: "medium", 3: "low"}


def iso(seconds):
    return (EPOCH + dt.timedelta(seconds=float(seconds))).strftime("%Y-%m-%dT%H:%M:%SZ") if seconds is not None else None


def date(spec):
    """Idea2do 的 DateSpec → 导出里的样子（WorkspaceExporter.ExportDate）。"""
    if not spec:
        return None
    got = spec.get("resolved") or {}
    out = {"raw": spec.get("raw"), "certainty": spec.get("certainty") or "unresolved", "day": None, "dateTime": None, "timeZone": None}
    if day := got.get("day"):
        out["day"] = f"{day['year']:04d}-{day['month']:02d}-{day['day']:02d}"
    elif when := got.get("dateTime"):
        out["dateTime"], out["timeZone"] = iso(when.get("_0")), when.get("timeZone")
    return out


def source(evidence):
    return {"captureID": evidence["captureID"], "quote": evidence.get("quote") or ""} if evidence else None


def rows(db, table):
    return [json.loads(r[0]) for r in db.execute(f"SELECT CAST(payload AS TEXT) FROM {table}")]


def attachment_text(a):
    """Idea2do 在本机识别出的文字（图片的 OCR、PDF 的文字层），按它存的顺序拼起来。"""
    return "\n".join(s.get("text") or "" for s in a.get("segments") or [] if s.get("text"))


def dump(db):
    captures = []
    for x in rows(db, "captures"):
        files = [{"path": HOME / "Attachments/Captures" / x["id"] / a["id"] / a["filename"], "name": a["filename"],
                  "text": attachment_text(a) if a.get("kind") == "image" else ""} for a in x.get("attachments") or []]
        captures.append({"id": x["id"], "text": x.get("text") or "", "source": x.get("source") or "typed", "createdAt": iso(x.get("createdAt")),
                         "timeZone": x.get("timeZoneIdentifier"), "status": x.get("status"), "_files": files})
    tasks = [{"id": x["id"], "title": x.get("title") or "", "status": x.get("status") or "open",
              "dueAt": date(x.get("dueAt")), "plannedAt": date(x.get("plannedAt")), "remindAt": date(x.get("remindAt")),
              "priority": PRIORITY.get(x.get("priority")), "userEditedFields": sorted(x.get("userEditedFields") or []),
              "source": source(x.get("evidence")), "createdAt": iso(x.get("createdAt"))} for x in rows(db, "tasks")]
    notes = [{"id": x["id"], "kind": x.get("kind") or "reference", "body": x.get("body") or "", "userEdited": bool(x.get("isUserEdited")),
              "source": source(x.get("evidence")), "createdAt": iso(x.get("createdAt"))} for x in rows(db, "notes")]
    memories = [{"id": x["id"], "statement": x.get("statement") or "", "enabled": x.get("enabled", True),
                 "source": source(x.get("evidence")), "createdAt": iso(x.get("createdAt"))} for x in rows(db, "memories")]
    matters = [{"id": x["id"], "title": x.get("title") or "", "state": x.get("state") or "active",
                "titleUserEdited": bool(x.get("isTitleUserEdited")), "createdAt": iso(x.get("createdAt")),
                "lastActivityAt": iso(x.get("lastActivityAt"))} for x in rows(db, "matters")]
    links = [{"matterID": x["matterID"], "itemID": x["itemID"], "itemKind": x.get("itemKind"), "role": x.get("role"),
              "captureID": (x.get("evidence") or {}).get("captureID"), "createdAt": iso(x.get("createdAt"))} for x in rows(db, "matter_links")]
    for group in (captures, tasks, notes, memories, matters):
        group.sort(key=lambda r: r["createdAt"] or "")
    return {"format": "idea2do-export", "version": 1, "exportedAt": iso((dt.datetime.now(dt.timezone.utc) - EPOCH).total_seconds()),
            "captures": captures, "tasks": tasks, "notes": notes, "memories": memories, "matters": matters, "matterLinks": links}


def call(server, token, method, path, body=None, raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(server + path, data=data, method=method, headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/octet-stream" if raw is not None else "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"服务器拒绝了 {path}（{e.code}）：{e.read().decode(errors='replace')[:300]}")


def main():
    path = HOME / "workspace.sqlite"
    if not path.exists():
        sys.exit(f"没找到 Idea2do 的数据：{path}")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    doc = dump(db)
    files = [f for c in doc["captures"] for f in c["_files"]]
    missing = [str(f["path"]) for f in files if not f["path"].exists()]
    print(f"Idea2do：{len(doc['captures'])} 条原文、{len(doc['tasks'])} 条待办、{len(doc['notes'])} 条笔记、{len(doc['memories'])} 条记忆、"
          f"{len(doc['matters'])} 个事件、{len(doc['matterLinks'])} 条归属、{len(files)} 个附件" + (f"（{len(missing)} 个文件不在了）" if missing else ""))
    if "--send" not in sys.argv:
        return print("没有发：加 --send 才导入")
    cfg = json.loads((Path(os.environ.get("P2B_CLIENT_HOME") or Path.home() / ".paper2brain-client") / "config.json").read_text())
    server, token = cfg["server"].rstrip("/"), cfg["server_token"]
    for c in doc["captures"]:
        sent = []
        for f in c.pop("_files"):
            if f["path"].exists():
                up = call(server, token, "PUT", "/api/bot/inputs?name=" + urllib.parse.quote(f["name"]), raw=f["path"].read_bytes())
                sent.append({"id": up["id"], "text": f["text"]})
        if sent:
            c["files"] = sent
    got = call(server, token, "POST", "/api/bot/idea2do/import", {"doc": doc})
    print("导入了：" + "、".join(f"{k} {v}" for k, v in got.items()) + "（0 表示之前已经导过）")


if __name__ == "__main__":
    main()
