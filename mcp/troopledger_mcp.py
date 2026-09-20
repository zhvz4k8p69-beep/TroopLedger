#!/usr/bin/env python3
"""TroopLedger MCP server — read-only ledger access plus bank-statement reconciliation.

Run as stdio:
    /opt/homebrew/bin/python3 mcp/troopledger_mcp.py

READ-ONLY BY DESIGN. The live store is CloudKit-synced SwiftData. Writing to it
from outside the app would bypass SwiftData's change tracking — the edits would
never sync and could corrupt the store — so every query runs against a throwaway
copy (see `snapshot()`), and reconciliation results go to a Markdown report plus a
JSON plan that the treasurer applies inside TroopLedger. The store is never opened
for writing.

Reconciliation workflow (also available as the `reconcile_statement` prompt):
 1. The AI reads the statement PDF (Claude's Read tool, DEVONthink's
    `get_record_text`, or `read_statement_pdf` here) and transcribes it into
    structured lines.
 2. `match_statement` checks the statement foots, matches each line against the
    uncleared ledger transactions, and flags ambiguous / unmatched items.
 3. `resolve_items` records the treasurer's decisions on the flagged items.
 4. `reconciliation_report` writes the report and the plan file.

The matcher mirrors the app's rules (`ReconciliationPolicy` / `FinanceEngine.clearedBalance`
in FinanceEngine.swift): a transaction is eligible when it belongs to the account, is
not already cleared, and is dated on or before the statement date; the cleared balance
is the opening balance plus every cleared signed amount through that date.
"""

from __future__ import annotations

import atexit
import json
import os
import re
import shutil
import signal
import sqlite3
import tempfile
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("troopledger")

# The app is sandboxed; the SwiftData store lives in its container. An env override
# lets tests point at a copy.
CONTAINER = (Path.home() / "Library/Containers/com.bettnet.TroopLedger/Data"
             / "Library/Application Support/TroopLedger.store")
STORE_OVERRIDE = os.environ.get("TROOPLEDGER_STORE")

# Reports, plans, and in-progress reconciliation sessions. Kept outside the repo
# (the repo is public) and inside the user's Documents so DEVONthink can index it.
RECON_DIR = Path(os.environ.get("TROOPLEDGER_RECON_DIR",
                                Path.home() / "Documents/TroopLedger Reconciliations"))

# Core Data stores dates as seconds since 2001-01-01 UTC, not the Unix epoch.
CORE_DATA_EPOCH = 978_307_200

REQUIRED_TABLES = {"ZACCOUNTRECORD", "ZLEDGERTRANSACTION", "ZRECONCILIATIONRECORD"}

PLAN_FORMAT = "troopledger-reconciliation-plan/1"

# Matching thresholds. Scores: exact amount 100, check-number match 60, date proximity
# up to 30, payee overlap up to 20. A pair below MIN_SCORE is not a candidate (unless the
# check numbers agree — those always surface, as a match or an amount discrepancy); a
# match below CONFIDENT_SCORE, or with a rival within MARGIN points, needs a human look.
MIN_SCORE = 80
CONFIDENT_SCORE = 120
MARGIN = 15
STALE_DAYS = 90          # an uncleared check older than this at statement date is flagged
IN_TRANSIT_DAYS = 5      # a deposit this close to the statement date may simply not have posted


# ---------------------------------------------------------------------------
# Store access (copy-then-read; the live store is never touched)
# ---------------------------------------------------------------------------

_cache: dict[str, object] = {"key": None, "dir": None}


def _discard_snapshot() -> None:
    """Remove the throwaway copy so a full copy of the ledger doesn't outlive the server."""
    old = _cache["dir"]
    _cache["key"], _cache["dir"] = None, None
    if old:
        shutil.rmtree(str(old), ignore_errors=True)


atexit.register(_discard_snapshot)


def _terminate(signum, _frame):
    """SIGTERM (how clients stop the server) skips atexit unless it becomes a normal exit."""
    raise SystemExit(0)


signal.signal(signal.SIGTERM, _terminate)


def store_path() -> Path:
    if STORE_OVERRIDE:
        p = Path(STORE_OVERRIDE).expanduser()
        if p.exists():
            return p
        raise FileNotFoundError(f"TROOPLEDGER_STORE points at a missing file: {p}")
    if CONTAINER.exists():
        return CONTAINER
    raise FileNotFoundError(
        f"No TroopLedger store found at {CONTAINER}. Open TroopLedger on this Mac at least once.")


def snapshot() -> Path:
    """Copy the store (plus -wal/-shm) somewhere disposable and return the copy.

    Recent data lives in the write-ahead log, so all three files are copied and the WAL
    is checkpointed into the copy. Re-copied only when the originals change.
    """
    src = store_path()
    parts = [src, src.with_name(src.name + "-wal"), src.with_name(src.name + "-shm")]
    key = str([(p.stat().st_mtime_ns, p.stat().st_size) for p in parts if p.exists()])

    if _cache["key"] == key and _cache["dir"] and Path(str(_cache["dir"])).exists():
        return Path(str(_cache["dir"])) / src.name

    tmp = Path(tempfile.mkdtemp(prefix="troopledger-mcp-"))
    try:
        for part in parts:
            if part.exists():
                dest = tmp / part.name
                shutil.copy2(part, dest)
                os.chmod(dest, 0o600)
        copy = tmp / src.name
        conn = sqlite3.connect(copy)
        try:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            if conn.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise sqlite3.DatabaseError("snapshot failed integrity check")
            tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not REQUIRED_TABLES <= tables:
                raise sqlite3.DatabaseError(
                    f"{src} is not a TroopLedger store (missing {sorted(REQUIRED_TABLES - tables)})")
        finally:
            conn.close()
    except BaseException:
        shutil.rmtree(str(tmp), ignore_errors=True)
        raise

    _discard_snapshot()
    _cache["key"], _cache["dir"] = key, tmp
    return tmp / src.name


def query(sql: str, params: tuple = ()) -> list[dict]:
    conn = sqlite3.connect(f"file:{snapshot()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute(sql, params)]
    finally:
        conn.close()


def store_fingerprint() -> str:
    src = store_path()
    parts = [src, src.with_name(src.name + "-wal")]
    return str([(p.stat().st_mtime_ns, p.stat().st_size) for p in parts if p.exists()])


# ---------------------------------------------------------------------------
# Conversions
# ---------------------------------------------------------------------------

def to_uuid(blob) -> str:
    if blob is None:
        return ""
    if isinstance(blob, (bytes, bytearray)) and len(blob) == 16:
        return str(uuid.UUID(bytes=bytes(blob)))
    return str(blob)


def to_local_date(zdate) -> date | None:
    if zdate is None:
        return None
    return datetime.fromtimestamp(float(zdate) + CORE_DATA_EPOCH, tz=timezone.utc).astimezone().date()


def money(cents: int) -> str:
    sign = "-" if cents < 0 else ""
    return f"{sign}${abs(int(cents)) / 100:,.2f}"


def to_cents(value) -> int:
    """'1,234.56', '(12.34)', '$5', 5, 5.0 → integer cents. Rounds half-up."""
    if value is None or value == "":
        return 0
    if isinstance(value, bool):
        raise ValueError("amount cannot be a boolean")
    if isinstance(value, int):
        return value * 100
    text = str(value).strip().replace(",", "").replace("$", "").replace(" ", "")
    negative = False
    if text.startswith("(") and text.endswith(")"):
        negative, text = True, text[1:-1]
    if text.endswith("-"):
        negative, text = True, text[:-1]
    if text.startswith("-"):
        negative, text = not negative, text[1:]
    if text.startswith("+"):
        text = text[1:]
    try:
        cents = int((Decimal(text) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    except InvalidOperation as exc:
        raise ValueError(f"cannot read amount {value!r}") from exc
    return -cents if negative else cents


DATE_FORMATS = ("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y", "%m-%d-%Y", "%b %d, %Y", "%B %d, %Y", "%d %b %Y", "%Y%m%d")


def parse_date(value, default_year: int | None = None) -> date:
    if isinstance(value, date):
        return value
    text = str(value or "").strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    # Statements often print MM/DD with the year only in the header.
    m = re.fullmatch(r"(\d{1,2})/(\d{1,2})", text)
    if m and default_year:
        return date(default_year, int(m.group(1)), int(m.group(2)))
    raise ValueError(f"cannot read date {value!r} (use YYYY-MM-DD)")


def digits_only(text: str) -> str:
    text = (text or "").strip()
    return text.lstrip("0") or "0" if text.isdigit() else ""


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------

def load_accounts() -> list[dict]:
    rows = query("SELECT ZID, ZNAME, ZINSTITUTION, ZKINDRAW, ZOPENINGBALANCECENTS, ZISACTIVE, ZNOTES "
                 "FROM ZACCOUNTRECORD ORDER BY ZNAME")
    return [{
        "id": to_uuid(r["ZID"]),
        "name": r["ZNAME"] or "",
        "institution": r["ZINSTITUTION"] or "",
        "kind": r["ZKINDRAW"] or "",
        "opening_cents": int(r["ZOPENINGBALANCECENTS"] or 0),
        "is_active": bool(r["ZISACTIVE"]),
        "notes": r["ZNOTES"] or "",
    } for r in rows]


def load_transactions(account_id: str | None = None) -> list[dict]:
    rows = query("SELECT ZID, ZACCOUNTID, ZDATE, ZDIRECTIONRAW, ZAMOUNTCENTS, ZCHECKNUMBER, ZPAYEE, ZCATEGORY, "
                 "ZMEMO, ZISCLEARED, ZRECONCILEDAT, ZRECONCILIATIONID, ZISADJUSTMENT, ZISTRANSFER, ZDEPOSITBATCHID, "
                 "ZPERSONID, ZEVENTID FROM ZLEDGERTRANSACTION")
    out = []
    for r in rows:
        acct = to_uuid(r["ZACCOUNTID"])
        if account_id and acct != account_id:
            continue
        amount = int(r["ZAMOUNTCENTS"] or 0)
        direction = r["ZDIRECTIONRAW"] or "Expense"
        raw_check = (r["ZCHECKNUMBER"] or "").strip()
        out.append({
            "id": to_uuid(r["ZID"]),
            "account_id": acct,
            "date": to_local_date(r["ZDATE"]),
            "direction": direction,
            "cents": amount if direction == "Income" else -amount,
            "check_number": digits_only(raw_check),
            "reference": raw_check,
            "payee": r["ZPAYEE"] or "",
            "category": r["ZCATEGORY"] or "",
            "memo": r["ZMEMO"] or "",
            "is_cleared": bool(r["ZISCLEARED"]),
            "reconciled_at": to_local_date(r["ZRECONCILEDAT"]),
            "reconciliation_id": to_uuid(r["ZRECONCILIATIONID"]),
            "is_adjustment": bool(r["ZISADJUSTMENT"]),
            "is_transfer": bool(r["ZISTRANSFER"]),
            "is_deposit_batch": r["ZDEPOSITBATCHID"] is not None,
        })
    out.sort(key=lambda t: (t["date"] or date.min, t["payee"], t["id"]))
    return out


def load_reconciliations(account_id: str | None = None) -> list[dict]:
    rows = query("SELECT ZID, ZACCOUNTID, ZSTATEMENTDATE, ZSTATEMENTENDINGBALANCECENTS, ZCLEAREDBALANCECENTS, "
                 "ZCOMPLETEDAT, ZNOTES FROM ZRECONCILIATIONRECORD")
    out = [{
        "id": to_uuid(r["ZID"]),
        "account_id": to_uuid(r["ZACCOUNTID"]),
        "statement_date": to_local_date(r["ZSTATEMENTDATE"]),
        "statement_ending_cents": int(r["ZSTATEMENTENDINGBALANCECENTS"] or 0),
        "cleared_cents": int(r["ZCLEAREDBALANCECENTS"] or 0),
        "completed_at": to_local_date(r["ZCOMPLETEDAT"]),
        "notes": r["ZNOTES"] or "",
    } for r in rows]
    if account_id:
        out = [r for r in out if r["account_id"] == account_id]
    out.sort(key=lambda r: r["statement_date"] or date.min, reverse=True)
    return out


def load_categories() -> list[dict]:
    try:
        rows = query("SELECT ZNAME, ZDIRECTIONRAW, ZISACTIVE FROM ZLEDGERCATEGORYRECORD ORDER BY ZSORTORDER, ZNAME")
    except sqlite3.OperationalError:
        return []
    return [{"name": r["ZNAME"] or "", "direction": r["ZDIRECTIONRAW"] or "", "is_active": bool(r["ZISACTIVE"])}
            for r in rows]


def load_profile() -> dict:
    try:
        rows = query("SELECT ZTROOPNAME, ZTROOPNUMBER, ZCOUNCIL, ZTREASURERNAME, ZCHARTEREDORGANIZATION "
                     "FROM ZTROOPPROFILERECORD LIMIT 1")
    except sqlite3.OperationalError:
        rows = []
    if not rows:
        return {}
    r = rows[0]
    return {"troop_name": r["ZTROOPNAME"] or "", "troop_number": r["ZTROOPNUMBER"] or "",
            "council": r["ZCOUNCIL"] or "", "treasurer": r["ZTREASURERNAME"] or "",
            "chartered_organization": r["ZCHARTEREDORGANIZATION"] or ""}


def resolve_account(account: str | None, accounts: list[dict] | None = None) -> dict:
    """Find an account by UUID or (partial, case-insensitive) name. With no argument,
    pick the only active checking account."""
    accounts = accounts if accounts is not None else load_accounts()
    if not accounts:
        raise ValueError("The ledger has no accounts yet.")
    needle = (account or "").strip().lower()
    if not needle:
        checking = [a for a in accounts if a["is_active"] and a["kind"] == "Checking"]
        if len(checking) == 1:
            return checking[0]
        names = ", ".join(a["name"] for a in accounts)
        raise ValueError(f"Say which account to use. Accounts: {names}")
    exact = [a for a in accounts if a["id"].lower() == needle or a["name"].lower() == needle]
    if len(exact) == 1:
        return exact[0]
    partial = [a for a in accounts if needle in a["name"].lower()]
    if len(partial) == 1:
        return partial[0]
    if not partial:
        names = ", ".join(a["name"] for a in accounts)
        raise ValueError(f"No account matches {account!r}. Accounts: {names}")
    raise ValueError(f"{account!r} is ambiguous: " + ", ".join(a["name"] for a in partial))


# ---------------------------------------------------------------------------
# Ledger arithmetic (mirrors FinanceEngine / ReconciliationPolicy)
# ---------------------------------------------------------------------------

def is_eligible(txn: dict, account_id: str, statement_date: date) -> bool:
    return (txn["account_id"] == account_id and not txn["is_cleared"]
            and txn["date"] is not None and txn["date"] <= statement_date)


def cleared_balance(account: dict, txns: list[dict], through: date | None = None,
                    additionally: set[str] | None = None) -> int:
    additionally = additionally or set()
    total = account["opening_cents"]
    for t in txns:
        if t["account_id"] != account["id"]:
            continue
        if not (t["is_cleared"] or t["id"] in additionally):
            continue
        if through is not None and (t["date"] is None or t["date"] > through):
            continue
        total += t["cents"]
    return total


def lock_date(reconciliations: list[dict]) -> date | None:
    dates = [r["statement_date"] for r in reconciliations if r["statement_date"]]
    return max(dates) if dates else None


# ---------------------------------------------------------------------------
# Statement lines
# ---------------------------------------------------------------------------

STOPWORDS = {"check", "chk", "ck", "deposit", "dep", "ach", "debit", "credit", "withdrawal", "payment",
             "pmt", "online", "electronic", "transfer", "xfer", "the", "of", "and", "to", "for", "inc",
             "llc", "co", "des", "id", "ppd", "web", "ccd", "pos", "purchase", "card", "mobile", "branch",
             "counter", "ref", "trace", "conf", "no", "number"}

CHECK_PATTERN = re.compile(r"\b(?:check|chk|ck)\s*#?\s*(\d+)\b", re.I)
FEE_PATTERN = re.compile(r"\b(fee|service charge|maintenance|overdraft|nsf|returned item|stop payment)\b", re.I)
INTEREST_PATTERN = re.compile(r"\binterest\b", re.I)


def tokens(text: str) -> set[str]:
    return {t for t in re.findall(r"[a-z0-9]+", (text or "").lower())
            if len(t) > 1 and t not in STOPWORDS and not t.isdigit()}


def similarity(a: str, b: str) -> float:
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


def guess_kind(description: str, cents: int, check: str) -> str:
    if FEE_PATTERN.search(description):
        return "fee"
    if INTEREST_PATTERN.search(description):
        return "interest"
    if check:
        return "check"
    return "deposit" if cents > 0 else "debit"


def normalize_lines(raw_lines: list, statement_date: date) -> list[dict]:
    """Validate and normalise the AI's transcription of the statement.

    Each line: {"date", "description", "amount"} with amount signed (+ into the account,
    - out of it), or "debit"/"credit" instead of "amount". Optional: "check_number",
    "type" (check/deposit/debit/fee/interest/other).
    """
    if not isinstance(raw_lines, list) or not raw_lines:
        raise ValueError("`lines` must be a non-empty list of statement lines")
    lines = []
    for index, raw in enumerate(raw_lines, start=1):
        if not isinstance(raw, dict):
            raise ValueError(f"line {index}: expected an object, got {type(raw).__name__}")
        try:
            line_date = parse_date(raw.get("date"), default_year=statement_date.year)
        except ValueError as exc:
            raise ValueError(f"line {index}: {exc}") from exc
        description = str(raw.get("description") or raw.get("memo") or "").strip()
        if raw.get("amount") not in (None, ""):
            cents = to_cents(raw["amount"])
        else:
            cents = to_cents(raw.get("credit")) - to_cents(raw.get("debit"))
        if cents == 0:
            raise ValueError(f"line {index} ({description!r}): amount is zero or missing")
        check = digits_only(str(raw.get("check_number") or ""))
        if not check:
            m = CHECK_PATTERN.search(description)
            if m:
                check = digits_only(m.group(1))
        kind = str(raw.get("type") or "").strip().lower() or guess_kind(description, cents, check)
        lines.append({"index": index, "date": line_date, "description": description,
                      "cents": cents, "check_number": check, "kind": kind})
    return lines


# ---------------------------------------------------------------------------
# Matcher (pure: statement lines × eligible ledger transactions)
# ---------------------------------------------------------------------------

def score_pair(line: dict, txn: dict) -> dict | None:
    amount_exact = line["cents"] == txn["cents"]
    lc, tc = line["check_number"], txn["check_number"]
    check_equal = bool(lc) and lc == tc
    if lc and tc and lc != tc:
        return None
    if not amount_exact and not check_equal:
        return None
    if line["cents"] * txn["cents"] < 0:
        return None
    score, reasons = 0, []
    if amount_exact:
        score += 100
        reasons.append("amount")
    else:
        reasons.append(f"amount differs by {money(line['cents'] - txn['cents'])}")
    if check_equal:
        score += 60
        reasons.append(f"check #{lc}")
    d = (line["date"] - txn["date"]).days
    if d == 0:
        pts = 30
    elif 1 <= d <= 3:
        pts = 25
    elif 4 <= d <= 14:
        pts = 20
    elif 15 <= d <= 30:
        pts = 10
    elif 31 <= d <= 60:
        pts = 0
    elif d > 60:
        pts = -20
    elif d == -1:
        pts = 15          # banks sometimes post a day before the treasurer's recorded date
    elif -5 <= d <= -2:
        pts = 0
    else:
        pts = -25         # bank cleared it well before the ledger says it happened
    score += pts
    reasons.append("same day" if d == 0 else f"{d:+d} days")
    sim = similarity(line["description"], txn["payee"])
    if sim > 0:
        score += round(20 * sim)
        reasons.append(f"payee {sim:.0%}")
    return {"score": score, "amount_exact": amount_exact, "check_equal": check_equal,
            "days": d, "reasons": reasons}


def run_matching(lines: list[dict], eligible: list[dict], cleared: list[dict],
                 resolutions: dict | None = None) -> dict:
    """Assign statement lines to ledger transactions one-to-one, best score first.

    `resolutions` (from `resolve_items`): forced {line_index: txn_id}, ignored
    {line_index: reason}, additions {line_index: {...}}, ledger_notes {txn_id: {...}}.
    """
    resolutions = resolutions or {}
    forced = {int(k): v for k, v in (resolutions.get("forced") or {}).items()}
    ignored = {int(k): v for k, v in (resolutions.get("ignored") or {}).items()}
    additions = {int(k): v for k, v in (resolutions.get("additions") or {}).items()}
    ledger_notes = resolutions.get("ledger_notes") or {}
    by_id = {t["id"]: t for t in eligible}
    decided_lines = set(forced) | set(ignored) | set(additions)
    forced_txns = set(forced.values())

    pairs = []
    for line in lines:
        if line["index"] in decided_lines:
            continue
        for txn in eligible:
            if txn["id"] in forced_txns:
                continue
            s = score_pair(line, txn)
            if s and (s["score"] >= MIN_SCORE or s["check_equal"]):
                pairs.append((s["score"], line["index"], txn["id"], s))
    pairs.sort(key=lambda p: (-p[0], p[1], p[2]))
    candidates: dict[int, list] = defaultdict(list)
    for score, li, tid, s in pairs:
        candidates[li].append((score, tid, s))
    assigned_line: dict[int, tuple[str, dict]] = {}
    assigned_txn: dict[str, int] = {}
    for score, li, tid, s in pairs:
        if li in assigned_line or tid in assigned_txn:
            continue
        assigned_line[li] = (tid, s)
        assigned_txn[tid] = li

    def txn_view(t: dict) -> dict:
        return {"transaction_id": t["id"], "date": t["date"].isoformat(), "amount": money(t["cents"]),
                "cents": t["cents"], "check_number": t["reference"], "payee": t["payee"],
                "category": t["category"], "memo": t["memo"]}

    def line_view(line: dict) -> dict:
        return {"line": line["index"], "date": line["date"].isoformat(), "description": line["description"],
                "amount": money(line["cents"]), "cents": line["cents"], "check_number": line["check_number"],
                "type": line["kind"]}

    matched, ambiguous, mismatched, unmatched, ignored_out, additions_out = [], [], [], [], [], []
    for line in lines:
        li = line["index"]
        if li in ignored:
            ignored_out.append({**line_view(line), "reason": ignored[li]})
            continue
        if li in additions:
            spec = additions[li]
            additions_out.append({**line_view(line), "add": spec})
            continue
        if li in forced:
            tid = forced[li]
            txn = by_id.get(tid)
            if txn is None:
                unmatched.append({**line_view(line), "kind": "missing_from_ledger",
                                  "note": f"forced match {tid} is no longer an eligible transaction; re-resolve",
                                  "already_cleared_candidates": [], "near_misses": []})
                continue
            s = score_pair(line, txn) or {"score": 0, "amount_exact": line["cents"] == txn["cents"],
                                          "reasons": ["resolved manually"]}
            entry = {**line_view(line), "ledger": txn_view(txn), "score": s["score"],
                     "reasons": ["resolved manually"] + [r for r in s["reasons"] if r != "resolved manually"]}
            if s["amount_exact"]:
                matched.append(entry)
            else:
                entry["difference_cents"] = line["cents"] - txn["cents"]
                entry["difference"] = money(entry["difference_cents"])
                mismatched.append(entry)
            continue
        if li in assigned_line:
            tid, s = assigned_line[li]
            txn = by_id[tid]
            entry = {**line_view(line), "ledger": txn_view(txn), "score": s["score"], "reasons": s["reasons"]}
            if not s["amount_exact"]:
                entry["difference_cents"] = line["cents"] - txn["cents"]
                entry["difference"] = money(entry["difference_cents"])
                mismatched.append(entry)
                continue
            rivals = [(sc, t, ss) for sc, t, ss in candidates[li]
                      if t != tid and t not in assigned_txn and sc >= s["score"] - MARGIN]
            if rivals or s["score"] < CONFIDENT_SCORE:
                why = ("other uncleared transactions fit almost as well" if rivals
                       else "weak match: " + ", ".join(s["reasons"]))
                entry["why"] = why
                entry["candidates"] = [{**txn_view(by_id[t]), "score": sc, "reasons": ss["reasons"],
                                        "tentative": t == tid}
                                       for sc, t, ss in [(s["score"], tid, s)] + rivals[:4]]
                ambiguous.append(entry)
            else:
                matched.append(entry)
            continue
        # No eligible transaction fits. Offer context so the reviewer can tell a bank fee
        # from a duplicate statement line or a transposed amount.
        already = [txn_view(t) for t in cleared
                   if t["cents"] == line["cents"] and t["date"] and abs((line["date"] - t["date"]).days) <= 45]
        near = []
        for t in eligible:
            if t["id"] in assigned_txn or t["id"] in forced_txns or t["cents"] * line["cents"] <= 0:
                continue
            diff = abs(t["cents"] - line["cents"])
            days = abs((line["date"] - t["date"]).days)
            if diff <= 100 or (days <= 3 and diff <= abs(line["cents"]) // 10):
                near.append({**txn_view(t), "difference": money(line["cents"] - t["cents"])})
        kind = {"fee": "bank_fee", "interest": "interest"}.get(line["kind"], "missing_from_ledger")
        unmatched.append({**line_view(line), "kind": kind,
                          "already_cleared_candidates": already[:3], "near_misses": near[:3]})

    matched_ids = {e["ledger"]["transaction_id"] for e in matched + ambiguous + mismatched}
    outstanding = []
    for t in eligible:
        if t["id"] in matched_ids:
            continue
        note = ledger_notes.get(t["id"])
        outstanding.append({**txn_view(t), "ledger_note": note})
    return {"matched": matched, "ambiguous": ambiguous, "amount_mismatches": mismatched,
            "unmatched_lines": unmatched, "ignored_lines": ignored_out, "additions": additions_out,
            "outstanding": outstanding}


def classify_outstanding(items: list[dict], period_start: date | None, statement_date: date) -> None:
    """Annotate unmatched eligible ledger items in place. Outstanding checks are normal;
    stale checks, in-period deposits that never posted, and electronic debits that never
    posted deserve a look (`attention`). Items dated before the statement period belong
    to an earlier statement and are described as such."""
    for item in items:
        d = date.fromisoformat(item["date"])
        age = (statement_date - d).days
        prior = bool(period_start and d < period_start)
        is_check = bool(digits_only(item["check_number"]))
        note = item.get("ledger_note") or {}
        item["attention"] = False
        if note.get("action") in ("void", "duplicate", "error"):
            item["status"] = note["action"]
            item["flag"] = f"treasurer marked this as {note['action']}: {note.get('note', '')}".strip()
            item["attention"] = True
            continue
        if item["cents"] > 0:
            if age <= IN_TRANSIT_DAYS:
                item["status"], item["flag"] = "deposit_in_transit", ""
            elif prior:
                item["status"] = "prior_period_deposit"
                item["flag"] = "predates this statement and is still uncleared — it belongs on an earlier statement"
            else:
                item["status"] = "missing_deposit"
                item["flag"] = f"deposit recorded {age} days before the statement date has not appeared at the bank"
                item["attention"] = True
        elif is_check:
            item["status"] = "prior_period_check" if prior else "outstanding_check"
            if age > STALE_DAYS:
                item["flag"] = f"check has been outstanding {age} days — confirm it was delivered or void it"
                item["attention"] = True
            else:
                item["flag"] = "outstanding from an earlier statement period" if prior else ""
        else:
            item["status"] = "prior_period_debit" if prior else "outstanding_debit"
            if age > IN_TRANSIT_DAYS:
                item["flag"] = ("non-check debit not on the statement — electronic payments usually post within days; "
                                "confirm it went through")
                item["attention"] = True
            else:
                item["flag"] = ""
        if note.get("note"):
            item["flag"] = (item["flag"] + "; " if item["flag"] else "") + f"note: {note['note']}"


def suggest_category(kind: str, categories: list[dict], direction: str = "") -> str:
    """Pick the ledger's own category for a bank fee or interest line; anything else is
    left Uncategorized for the treasurer. Patterns are tried in order so 'Bank Fees'
    wins over 'Registration Fees'."""
    pool = [c for c in categories if c["is_active"]] or categories
    if direction:
        pool = [c for c in pool if c["direction"] == direction] or pool
    names = [c["name"] for c in pool]
    patterns = {"bank_fee": (r"^bank", r"bank (fee|charge|service)", r"service charge", r"^fees?$"),
                "interest": (r"interest",)}.get(kind, ())
    for pattern in patterns:
        for name in names:
            if re.search(pattern, name, re.I):
                return name
    return "Uncategorized"


# ---------------------------------------------------------------------------
# Sessions (a reconciliation in progress, persisted so decisions survive restarts)
# ---------------------------------------------------------------------------

def safe_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9 _-]+", "", text).strip() or "Account"


def session_path(account_name: str, statement_date: date) -> Path:
    return RECON_DIR / f"{safe_name(account_name)} {statement_date.isoformat()}.json"


def load_session(session: str) -> dict:
    p = Path(session).expanduser()
    if not p.is_absolute():
        p = RECON_DIR / p
    if not p.exists() and not p.name.endswith(".json"):
        p = p.with_name(p.name + ".json")
    if not p.exists():
        raise FileNotFoundError(f"No reconciliation session at {p}. Run match_statement first.")
    data = json.loads(p.read_text())
    data["_path"] = str(p)
    return data


def save_session(data: dict) -> Path:
    RECON_DIR.mkdir(parents=True, exist_ok=True)
    p = Path(data["_path"])
    body = {k: v for k, v in data.items() if not k.startswith("_")}
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(body, indent=1, default=str))
    os.chmod(tmp, 0o600)
    tmp.replace(p)
    return p


def compute(session: dict) -> dict:
    """Re-run the matcher for a session against the current store and assemble the
    full result (matches, balances, classifications)."""
    accounts = load_accounts()
    account = next((a for a in accounts if a["id"] == session["account_id"]), None)
    if account is None:
        raise ValueError(f"Account {session['account_id']} no longer exists in the ledger")
    statement_date = date.fromisoformat(session["statement_date"])
    txns = load_transactions(account["id"])
    recs = load_reconciliations(account["id"])
    lock = lock_date(recs)
    previous = recs[0] if recs else None
    eligible = [t for t in txns if is_eligible(t, account["id"], statement_date)]
    cleared = [t for t in txns if t["is_cleared"]]
    lines = [{**l, "date": date.fromisoformat(l["date"])} for l in session["lines"]]
    result = run_matching(lines, eligible, cleared, session.get("resolutions"))
    period_start = (date.fromisoformat(session["period_start"]) if session.get("period_start")
                    else (lock + timedelta(days=1)) if lock else None)
    classify_outstanding(result["outstanding"], period_start, statement_date)

    categories = load_categories()
    proposed = []
    for u in result["unmatched_lines"]:
        direction = "Income" if u["cents"] > 0 else "Expense"
        cat = suggest_category(u["kind"], categories, direction)
        proposed.append({"line": u["line"], "date": u["date"], "direction": direction,
                         "amount_cents": abs(u["cents"]), "amount": u["amount"],
                         "payee": u["description"][:60], "category": cat, "check_number": u["check_number"],
                         "memo": f"Per bank statement {statement_date.isoformat()}", "status": "proposed",
                         "why": {"bank_fee": "bank fee on statement, not in ledger",
                                 "interest": "interest credited by the bank, not in ledger"}.get(
                                     u["kind"], "on the statement but not in the ledger — confirm before adding")})
    for a in result["additions"]:
        spec = a["add"] or {}
        direction = spec.get("direction", "Income" if a["cents"] > 0 else "Expense")
        amount_cents = abs(to_cents(spec["amount"])) if spec.get("amount") else abs(a["cents"])
        proposed.append({"line": a["line"], "date": spec.get("date", a["date"]), "direction": direction,
                         "amount_cents": amount_cents,
                         "amount": money(amount_cents if direction == "Income" else -amount_cents),
                         "payee": spec.get("payee") or a["description"][:60],
                         "category": spec.get("category") or suggest_category(
                             {"fee": "bank_fee"}.get(a["type"], a["type"]), categories, direction),
                         "check_number": spec.get("check_number", a["check_number"]),
                         "memo": spec.get("memo", f"Per bank statement {statement_date.isoformat()}"),
                         "status": "accepted", "why": spec.get("reason", "accepted by treasurer")})
    for m in result["amount_mismatches"]:
        diff = m["difference_cents"]
        proposed.append({"line": m["line"], "date": m["date"], "direction": "Income" if diff > 0 else "Expense",
                         "amount_cents": abs(diff), "amount": money(diff),
                         "payee": m["ledger"]["payee"], "category": m["ledger"]["category"],
                         "check_number": "", "adjusts_transaction_id": m["ledger"]["transaction_id"],
                         "memo": f"Adjust {('check #' + m['check_number']) if m['check_number'] else 'item'} "
                                 f"to bank amount {m['amount']}",
                         "status": "proposed",
                         "why": f"bank cleared {m['amount']} but the ledger has {m['ledger']['amount']}"})

    def signed(p: dict) -> int:
        return p["amount_cents"] if p["direction"] == "Income" else -p["amount_cents"]

    cleared_before = cleared_balance(account, txns, through=statement_date)
    confident_ids = {e["ledger"]["transaction_id"] for e in result["matched"]}
    tentative_ids = {e["ledger"]["transaction_id"] for e in result["ambiguous"] + result["amount_mismatches"]}
    cleared_confident = cleared_before + sum(t["cents"] for t in eligible if t["id"] in confident_ids)
    cleared_all = cleared_confident + sum(t["cents"] for t in eligible if t["id"] in tentative_ids)
    ending = session["ending_cents"]
    adjustments_net = sum(signed(p) for p in proposed)
    accepted_net = sum(signed(p) for p in proposed if p["status"] == "accepted")
    difference = ending - cleared_all
    after_adjustments = difference - adjustments_net

    stmt_total = sum(l["cents"] for l in lines)
    deposits = sum(l["cents"] for l in lines if l["cents"] > 0)
    withdrawals = sum(l["cents"] for l in lines if l["cents"] < 0)
    beginning = session.get("beginning_cents")
    foot = None
    if beginning is not None:
        foot = {"beginning": money(beginning), "deposits": money(deposits), "withdrawals": money(withdrawals),
                "computed_ending": money(beginning + stmt_total), "stated_ending": money(ending),
                "foots": beginning + stmt_total == ending}
    beginning_check = None
    if beginning is not None:
        if previous:
            expected, source = previous["statement_ending_cents"], f"previous reconciliation ({previous['statement_date']})"
        else:
            expected, source = cleared_before, "ledger cleared balance before this statement"
        beginning_check = {"statement_beginning": money(beginning), "expected": money(expected), "source": source,
                           "agrees": beginning == expected}

    return {
        "session": session["_path"],
        "account": {"id": account["id"], "name": account["name"], "institution": account["institution"]},
        "statement_date": statement_date.isoformat(),
        "period_start": period_start.isoformat() if period_start else None,
        "locked_through": lock.isoformat() if lock else None,
        "previous_reconciliation": ({"statement_date": previous["statement_date"].isoformat(),
                                     "ending_balance": money(previous["statement_ending_cents"])} if previous else None),
        "statement": {"lines": len(lines), "deposits": money(deposits), "withdrawals": money(withdrawals),
                      "net": money(stmt_total), "foot": foot, "beginning_balance_check": beginning_check},
        "balances": {
            "statement_ending": money(ending),
            "ledger_cleared_before_this_statement": money(cleared_before),
            "cleared_after_confident_matches": money(cleared_confident),
            "cleared_after_all_matches": money(cleared_all),
            "difference": money(difference),
            "difference_cents": difference,
            "proposed_adjustments_net": money(adjustments_net),
            "accepted_adjustments_net": money(accepted_net),
            "difference_after_adjustments": money(after_adjustments),
            "difference_after_adjustments_cents": after_adjustments,
            "ties_after_adjustments": after_adjustments == 0,
        },
        "counts": {"matched": len(result["matched"]), "ambiguous": len(result["ambiguous"]),
                   "amount_mismatches": len(result["amount_mismatches"]),
                   "unmatched_lines": len(result["unmatched_lines"]), "ignored_lines": len(result["ignored_lines"]),
                   "additions": len(result["additions"]), "outstanding": len(result["outstanding"]),
                   "eligible_transactions": len(eligible)},
        "matched": result["matched"],
        "ambiguous": result["ambiguous"],
        "amount_mismatches": result["amount_mismatches"],
        "unmatched_lines": result["unmatched_lines"],
        "ignored_lines": result["ignored_lines"],
        "proposed_adjustments": proposed,
        "outstanding": result["outstanding"],
        "needs_review": len(result["ambiguous"]) + len(result["amount_mismatches"]) + len(result["unmatched_lines"]),
    }


# ---------------------------------------------------------------------------
# Report + plan rendering
# ---------------------------------------------------------------------------

def md_table(headers: list[str], rows: list[list[str]]) -> str:
    esc = lambda s: str(s).replace("|", "\\|").replace("\n", " ")
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    out += ["| " + " | ".join(esc(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def render_report(res: dict, profile: dict, prepared: date) -> str:
    acct, bal, stmt = res["account"], res["balances"], res["statement"]
    troop = profile.get("troop_name") or (f"Troop {profile['troop_number']}" if profile.get("troop_number") else "")
    header = f"# Bank Reconciliation — {acct['name']} — statement ending {res['statement_date']}\n"
    meta = [f"**Prepared:** {prepared.isoformat()}"]
    if troop:
        meta.insert(0, f"**{troop}**" + (f" · {profile['council']}" if profile.get("council") else ""))
    if acct.get("institution"):
        meta.append(f"**Institution:** {acct['institution']}")
    period = f"{res['period_start'] or 'ledger start'} – {res['statement_date']}"
    meta.append(f"**Period:** {period}")
    meta.append("**Previous reconciliation:** " + (
        f"{res['previous_reconciliation']['statement_date']} ending {res['previous_reconciliation']['ending_balance']}"
        if res["previous_reconciliation"] else "none (first reconciliation for this account)"))
    lines = [header, "  \n".join(meta), ""]

    tie = "✅ ties" if bal["ties_after_adjustments"] else "⚠️ does not tie"
    tentative = res["counts"]["ambiguous"] + res["counts"]["amount_mismatches"]
    rows = [["Statement ending balance", bal["statement_ending"]],
            ["Ledger cleared balance before this statement", bal["ledger_cleared_before_this_statement"]],
            [f"Cleared after the {res['counts']['matched']} confident matches", bal["cleared_after_confident_matches"]]]
    if tentative:
        rows.append([f"Cleared after all {res['counts']['matched'] + tentative} matches (incl. {tentative} tentative)",
                     bal["cleared_after_all_matches"]])
    rows += [["Difference (statement − ledger)", bal["difference"]],
             [f"Adjustments to enter (net, {len(res['proposed_adjustments'])} items)", bal["proposed_adjustments_net"]],
             ["Difference after adjustments", f"{bal['difference_after_adjustments']} {tie}"]]
    lines += ["## Summary", "", md_table(["", "Amount"], rows), ""]
    foot = stmt.get("foot")
    if foot:
        lines.append(f"Statement foots: {'✅' if foot['foots'] else '❌'} {foot['beginning']} + {foot['deposits']} "
                     f"− {foot['withdrawals'].lstrip('-')} = {foot['computed_ending']} (stated {foot['stated_ending']})  ")
    bc = stmt.get("beginning_balance_check")
    if bc:
        lines.append(f"Beginning balance vs {bc['source']}: {'✅ agrees' if bc['agrees'] else '⚠️ differs'} "
                     f"({bc['statement_beginning']} vs {bc['expected']})  ")
    lines.append(f"Statement lines: {stmt['lines']} · deposits {stmt['deposits']} · withdrawals {stmt['withdrawals']}")
    lines.append("")

    review = res["ambiguous"] + res["amount_mismatches"] + res["unmatched_lines"]
    lines += [f"## Needs manual review ({len(review)})", ""]
    if not review:
        lines.append("Nothing — every statement line matched a ledger transaction or has an accepted disposition.")
    if res["ambiguous"]:
        lines += ["### Ambiguous matches", "",
                  "Tentative pick shown first; alternatives follow. Resolve with `resolve_items`.", ""]
        for e in res["ambiguous"]:
            lines.append(f"- **Line {e['line']}** {e['date']} {e['description']} {e['amount']} — {e['why']}")
            for c in e["candidates"]:
                mark = "→" if c["tentative"] else " "
                lines.append(f"    - {mark} {c['date']} #{c['check_number'] or '—'} {c['payee']} {c['amount']} "
                             f"({c['category']}) score {c['score']} `{c['transaction_id']}`")
        lines.append("")
    if res["amount_mismatches"]:
        lines += ["### Amount discrepancies (same check number, different amount)", "",
                  md_table(["Line", "Bank date", "Check", "Bank amount", "Ledger date", "Payee", "Ledger amount", "Difference"],
                           [[e["line"], e["date"], e["check_number"], e["amount"], e["ledger"]["date"],
                             e["ledger"]["payee"], e["ledger"]["amount"], e["difference"]] for e in res["amount_mismatches"]]),
                  ""]
    if res["unmatched_lines"]:
        lines += ["### On the statement but not in the ledger", ""]
        for u in res["unmatched_lines"]:
            label = {"bank_fee": "bank fee", "interest": "interest"}.get(u["kind"], "no ledger entry")
            lines.append(f"- **Line {u['line']}** {u['date']} {u['description']} {u['amount']} — {label}")
            for c in u["already_cleared_candidates"]:
                lines.append(f"    - already cleared earlier: {c['date']} #{c['check_number'] or '—'} {c['payee']} {c['amount']}"
                             " — possible duplicate on the statement or a re-presented item")
            for c in u["near_misses"]:
                lines.append(f"    - near miss: {c['date']} #{c['check_number'] or '—'} {c['payee']} {c['amount']} "
                             f"(off by {c['difference']}) — transposition or partial payment?")
        lines.append("")

    lines += [f"## Adjustments to enter in TroopLedger ({len(res['proposed_adjustments'])})", ""]
    if res["proposed_adjustments"]:
        lines += [md_table(["Status", "Date", "Payee", "Direction", "Amount", "Category", "Memo", "Why"],
                           [[p["status"], p["date"], p["payee"], p["direction"], p["amount"], p["category"],
                             p["memo"], p["why"]] for p in res["proposed_adjustments"]]), "",
                  "Enter these before finishing the reconciliation so they can be cleared with the rest.", ""]
    else:
        lines += ["None.", ""]

    lines += [f"## Items to clear ({res['counts']['matched'] + res['counts']['ambiguous'] + res['counts']['amount_mismatches']})", ""]
    rows = []
    for e in res["matched"]:
        rows.append(["✓", e["date"], e["description"], e["amount"], e["ledger"]["date"], e["ledger"]["check_number"],
                     e["ledger"]["payee"], ", ".join(e["reasons"])])
    for e in res["ambiguous"]:
        rows.append(["?", e["date"], e["description"], e["amount"], e["ledger"]["date"], e["ledger"]["check_number"],
                     e["ledger"]["payee"], "tentative — see review"])
    for e in res["amount_mismatches"]:
        rows.append(["Δ", e["date"], e["description"], e["amount"], e["ledger"]["date"], e["ledger"]["check_number"],
                     e["ledger"]["payee"], f"ledger {e['ledger']['amount']}"])
    lines += [md_table(["", "Bank date", "Bank description", "Amount", "Ledger date", "Ref", "Payee", "Basis"], rows)
              if rows else "None.", ""]

    if res["ignored_lines"]:
        lines += ["## Statement lines set aside", "",
                  md_table(["Line", "Date", "Description", "Amount", "Reason"],
                           [[i["line"], i["date"], i["description"], i["amount"], i["reason"]] for i in res["ignored_lines"]]),
                  ""]

    lines += [f"## Outstanding ledger items carried forward ({len(res['outstanding'])})", ""]
    if res["outstanding"]:
        rows = [[o["date"], o["check_number"], o["payee"], o["amount"], o["status"].replace("_", " "), o["flag"]]
                for o in res["outstanding"]]
        lines += [md_table(["Ledger date", "Ref", "Payee", "Amount", "Status", "Flag"], rows), ""]
        flagged = [o for o in res["outstanding"] if o.get("attention")]
        total = sum(o["cents"] for o in res["outstanding"])
        lines.append(f"Net outstanding {money(total)}; {len(flagged)} need attention.")
    else:
        lines.append("None — every eligible ledger transaction appeared on this statement.")
    lines.append("")

    lines += ["## Finishing in TroopLedger", "",
              "**With the plan file:** open **Reconcile → Import Plan…**, choose the `.plan.json` written alongside this "
              "report, review the preview (it re-checks every item against the live ledger and shows the difference), "
              "and press **Apply Plan**. That adds the adjustments, clears the items, and locks the period in one step.",
              "",
              "**By hand:**",
              "1. Enter each adjustment above as a new transaction (Transactions → New), dated as shown.",
              f"2. Open **Reconcile**, choose *{acct['name']}*, set the statement date to {res['statement_date']} and the "
              f"ending balance to {bal['statement_ending']}.",
              "3. Tick every item in *Items to clear*, plus the adjustments you just entered.",
              "4. The difference should read $0.00; press **Finish Reconciliation** to lock the period.",
              "", "_Generated by the TroopLedger reconciliation MCP. The ledger was not modified._", ""]
    return "\n".join(lines)


def render_plan(res: dict, session: dict) -> dict:
    clear_ids = [e["ledger"]["transaction_id"] for e in res["matched"] + res["ambiguous"] + res["amount_mismatches"]]
    return {
        "format": PLAN_FORMAT,
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "account_id": res["account"]["id"],
        "account_name": res["account"]["name"],
        "statement_date": res["statement_date"],
        "statement_ending_balance_cents": session["ending_cents"],
        "statement_beginning_balance_cents": session.get("beginning_cents"),
        "clear_transaction_ids": sorted(clear_ids),
        "tentative_transaction_ids": sorted(e["ledger"]["transaction_id"] for e in res["ambiguous"] + res["amount_mismatches"]),
        "add_transactions": [{k: p[k] for k in ("date", "direction", "amount_cents", "payee", "category", "check_number", "memo")}
                             | ({"adjusts_transaction_id": p["adjusts_transaction_id"]} if p.get("adjusts_transaction_id") else {})
                             | {"status": p["status"]}
                             for p in res["proposed_adjustments"]],
        "ties_after_adjustments": res["balances"]["ties_after_adjustments"],
        "needs_review": res["needs_review"],
        "notes": session.get("notes", ""),
    }


# ---------------------------------------------------------------------------
# Tools: ledger reads
# ---------------------------------------------------------------------------

def dump(obj) -> str:
    return json.dumps(obj, indent=1, default=str)


@mcp.tool()
def list_accounts() -> str:
    """List the ledger's accounts with opening balance, current cleared and book balances,
    uncleared count, and the date each is locked through by its last reconciliation."""
    accounts = load_accounts()
    txns = load_transactions()
    recs = load_reconciliations()
    out = []
    for a in accounts:
        mine = [t for t in txns if t["account_id"] == a["id"]]
        lock = lock_date([r for r in recs if r["account_id"] == a["id"]])
        uncleared = [t for t in mine if not t["is_cleared"]]
        out.append({
            "id": a["id"], "name": a["name"], "institution": a["institution"], "kind": a["kind"],
            "is_active": a["is_active"], "opening_balance": money(a["opening_cents"]),
            "book_balance": money(a["opening_cents"] + sum(t["cents"] for t in mine)),
            "cleared_balance": money(cleared_balance(a, mine)),
            "uncleared_count": len(uncleared), "uncleared_net": money(sum(t["cents"] for t in uncleared)),
            "locked_through": lock.isoformat() if lock else None,
            "transaction_count": len(mine),
        })
    return dump(out)


@mcp.tool()
def reconciliation_status(account: str = "") -> str:
    """Where reconciliation stands for an account: last reconciliation, lock date,
    uncleared items, and the suggested next statement date. `account` may be a name
    fragment or UUID; empty picks the only active checking account."""
    acct = resolve_account(account)
    txns = load_transactions(acct["id"])
    recs = load_reconciliations(acct["id"])
    lock = lock_date(recs)
    today = date.today()
    uncleared = [t for t in txns if not t["is_cleared"]]
    if lock:
        nxt = (lock.replace(day=1) + timedelta(days=62)).replace(day=1) - timedelta(days=1)
        suggested = min(nxt, today)
    else:
        suggested = today.replace(day=1) - timedelta(days=1)
    return dump({
        "account": {"id": acct["id"], "name": acct["name"], "institution": acct["institution"],
                    "opening_balance": money(acct["opening_cents"])},
        "locked_through": lock.isoformat() if lock else None,
        "reconciliations": [{"statement_date": r["statement_date"].isoformat(),
                             "statement_ending_balance": money(r["statement_ending_cents"]),
                             "cleared_balance": money(r["cleared_cents"]), "completed": str(r["completed_at"]),
                             "notes": r["notes"]} for r in recs[:12]],
        "cleared_balance_today": money(cleared_balance(acct, txns)),
        "book_balance_today": money(acct["opening_cents"] + sum(t["cents"] for t in txns)),
        "uncleared": {"count": len(uncleared), "net": money(sum(t["cents"] for t in uncleared)),
                      "oldest": min((t["date"] for t in uncleared if t["date"]), default=None),
                      "newest": max((t["date"] for t in uncleared if t["date"]), default=None)},
        "already_cleared_without_reconciliation": sum(1 for t in txns if t["is_cleared"] and not t["reconciliation_id"]),
        "suggested_next_statement_date": suggested.isoformat(),
        "sessions_in_progress": sorted(p.name for p in RECON_DIR.glob(f"{safe_name(acct['name'])} *.json")) if RECON_DIR.exists() else [],
    })


@mcp.tool()
def uncleared_transactions(account: str = "", through: str = "") -> str:
    """The transactions a statement could clear: uncleared, on the account, dated on or
    before `through` (YYYY-MM-DD; default today). This is exactly the set TroopLedger's
    Reconcile screen offers for that statement date."""
    acct = resolve_account(account)
    stmt = parse_date(through) if through else date.today()
    txns = [t for t in load_transactions(acct["id"]) if is_eligible(t, acct["id"], stmt)]
    return dump({"account": acct["name"], "through": stmt.isoformat(), "count": len(txns),
                 "net": money(sum(t["cents"] for t in txns)),
                 "cleared_balance_through": money(cleared_balance(acct, load_transactions(acct["id"]), through=stmt)),
                 "transactions": [{"transaction_id": t["id"], "date": t["date"].isoformat(), "amount": money(t["cents"]),
                                   "check_number": t["reference"], "payee": t["payee"], "category": t["category"],
                                   "memo": t["memo"]} for t in txns]})


@mcp.tool()
def register(account: str = "", start: str = "", end: str = "", include_cleared: bool = True, limit: int = 200) -> str:
    """Account register between two dates (YYYY-MM-DD, inclusive), newest first, with a
    running book balance."""
    acct = resolve_account(account)
    txns = load_transactions(acct["id"])
    s = parse_date(start) if start else None
    e = parse_date(end) if end else None
    running = acct["opening_cents"]
    rows = []
    for t in txns:
        running += t["cents"]
        if s and t["date"] < s:
            continue
        if e and t["date"] > e:
            continue
        if not include_cleared and t["is_cleared"]:
            continue
        rows.append({"transaction_id": t["id"], "date": t["date"].isoformat(), "amount": money(t["cents"]),
                     "check_number": t["reference"], "payee": t["payee"], "category": t["category"], "memo": t["memo"],
                     "cleared": t["is_cleared"], "balance": money(running)})
    rows.reverse()
    return dump({"account": acct["name"], "count": len(rows), "transactions": rows[:max(1, limit)]})


@mcp.tool()
def search_transactions(text: str = "", amount: str = "", check_number: str = "", start: str = "", end: str = "",
                        account: str = "", limit: int = 50) -> str:
    """Find transactions by payee/memo/category text, exact amount (either sign), check
    number, and/or date range. Useful for chasing an unmatched statement line."""
    acct_id = resolve_account(account)["id"] if account else None
    txns = load_transactions(acct_id)
    needle = text.strip().lower()
    cents = abs(to_cents(amount)) if amount else None
    chk = digits_only(check_number)
    s = parse_date(start) if start else None
    e = parse_date(end) if end else None
    rows = []
    for t in txns:
        if needle and needle not in f"{t['payee']} {t['memo']} {t['category']}".lower():
            continue
        if cents is not None and abs(t["cents"]) != cents:
            continue
        if chk and t["check_number"] != chk:
            continue
        if s and t["date"] < s:
            continue
        if e and t["date"] > e:
            continue
        rows.append({"transaction_id": t["id"], "account_id": t["account_id"], "date": t["date"].isoformat(),
                     "amount": money(t["cents"]), "check_number": t["reference"], "payee": t["payee"],
                     "category": t["category"], "memo": t["memo"], "cleared": t["is_cleared"]})
    rows.reverse()
    return dump({"count": len(rows), "transactions": rows[:max(1, limit)]})


# ---------------------------------------------------------------------------
# Tools: statement reconciliation
# ---------------------------------------------------------------------------

@mcp.tool()
def read_statement_pdf(path: str, max_chars: int = 60000) -> str:
    """Extract the text layer of a statement PDF (needs `pypdf`; scanned statements have
    no text layer — OCR them in DEVONthink first, or read the PDF directly with the
    Read tool / DEVONthink `get_record_text` instead)."""
    p = Path(path).expanduser()
    if not p.exists():
        raise FileNotFoundError(f"{p} does not exist")
    if p.suffix.lower() != ".pdf":
        raise ValueError("read_statement_pdf only reads .pdf files")
    try:
        from pypdf import PdfReader  # optional dependency
    except ImportError as exc:
        raise RuntimeError("pypdf is not installed (`/opt/homebrew/bin/python3 -m pip install pypdf`). "
                           "Alternatively read the PDF with the Read tool or DEVONthink's get_record_text.") from exc
    reader = PdfReader(str(p))
    pages = []
    for i, page in enumerate(reader.pages, start=1):
        pages.append(f"--- page {i} ---\n{page.extract_text() or ''}")
    text = "\n".join(pages)
    if not text.strip().replace("--- page", ""):
        return "No text layer found. This looks like a scanned statement: OCR it (DEVONthink → ocr_record) first."
    return text[:max_chars]


@mcp.tool()
def match_statement(statement_date: str, ending_balance: str, lines: list[dict], account: str = "",
                    beginning_balance: str = "", period_start: str = "", notes: str = "") -> str:
    """Match a transcribed bank statement against the ledger and start a reconciliation session.

    `lines`: every transaction on the statement, in order, each as
    {"date": "YYYY-MM-DD", "description": "...", "amount": -118.75} — amount is signed
    (positive into the account, negative out), or give "debit"/"credit" instead of
    "amount". Optional per line: "check_number", "type" (check/deposit/debit/fee/interest).
    Include bank fees and interest; do NOT include the beginning/ending balance rows.

    Give `beginning_balance` whenever the statement shows it: the tool then proves the
    transcription foots (beginning + lines = ending) before matching, which catches
    misread digits early. `period_start` (YYYY-MM-DD) is the statement's first day; it
    defaults to the day after the account's lock date and only affects how outstanding
    ledger items are described.

    Returns the match result: confident matches, ambiguous matches (with candidates),
    amount discrepancies, statement lines missing from the ledger (with proposed
    adjustments), outstanding ledger items, and the balance arithmetic. Saves a session
    file whose path is returned as `session`; pass it to resolve_items and
    reconciliation_report.
    """
    acct = resolve_account(account)
    stmt_date = parse_date(statement_date)
    if stmt_date > date.today():
        raise ValueError("The statement date is in the future; TroopLedger will refuse to lock through it.")
    ending = to_cents(ending_balance)
    beginning = to_cents(beginning_balance) if beginning_balance not in ("", None) else None
    norm = normalize_lines(lines, stmt_date)
    recs = load_reconciliations(acct["id"])
    lock = lock_date(recs)
    if lock and stmt_date <= lock:
        raise ValueError(f"{acct['name']} is already reconciled through {lock}; choose a later statement date.")
    if beginning is not None:
        total = sum(l["cents"] for l in norm)
        if beginning + total != ending:
            return dump({"status": "statement_does_not_foot",
                         "message": "beginning + lines ≠ ending. Re-check the transcription (a misread digit, a "
                                    "missed line, or a sign flip) before matching.",
                         "beginning": money(beginning), "sum_of_lines": money(total),
                         "computed_ending": money(beginning + total), "stated_ending": money(ending),
                         "off_by": money(ending - (beginning + total)),
                         "hint": "If off_by equals one line's amount, that line is missing or duplicated; if it is "
                                 "twice a line's amount, that line's sign is flipped.",
                         "line_count": len(norm)})
    session = {
        "_path": str(session_path(acct["name"], stmt_date)),
        "account_id": acct["id"], "account_name": acct["name"],
        "statement_date": stmt_date.isoformat(), "ending_cents": ending, "beginning_cents": beginning,
        "period_start": parse_date(period_start).isoformat() if period_start else None,
        "lines": [{**l, "date": l["date"].isoformat()} for l in norm],
        "resolutions": {"forced": {}, "ignored": {}, "additions": {}, "ledger_notes": {}},
        "notes": notes, "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    existing = Path(session["_path"])
    if existing.exists():
        try:
            old = json.loads(existing.read_text())
            if old.get("lines") == session["lines"]:
                session["resolutions"] = old.get("resolutions", session["resolutions"])
                session["notes"] = session["notes"] or old.get("notes", "")
        except (json.JSONDecodeError, OSError):
            pass
    save_session(session)
    res = compute(session)
    res["status"] = "ok"
    res["next"] = ("Walk the treasurer through `ambiguous`, `amount_mismatches`, and `unmatched_lines`; record "
                   "decisions with resolve_items, then call reconciliation_report."
                   if res["needs_review"] else "Nothing needs review — call reconciliation_report.")
    return dump(res)


@mcp.tool()
def resolve_items(session: str, resolutions: list[dict]) -> str:
    """Record the treasurer's decisions on flagged items and re-run the match.

    Each resolution is one of:
      {"line": 5, "transaction_id": "<uuid>"}            confirm which ledger item a line clears
      {"line": 7, "action": "add", "payee": "...", "category": "...", "memo": "...", "reason": "..."}
                                                          accept a statement line as a new ledger transaction
                                                          (fields default from the line)
      {"line": 8, "action": "ignore", "reason": "..."}    set a statement line aside (e.g. duplicated line)
      {"line": 5, "action": "auto"}                       drop an earlier decision for that line
      {"transaction_id": "<uuid>", "action": "void" | "duplicate" | "error" | "note", "note": "..."}
                                                          annotate an outstanding ledger item
    Returns the updated match result.
    """
    data = load_session(session)
    r = data.setdefault("resolutions", {"forced": {}, "ignored": {}, "additions": {}, "ledger_notes": {}})
    for key in ("forced", "ignored", "additions", "ledger_notes"):
        r.setdefault(key, {})
    line_count = len(data["lines"])
    stmt_date = date.fromisoformat(data["statement_date"])
    eligible_ids = {t["id"] for t in load_transactions(data["account_id"])
                    if is_eligible(t, data["account_id"], stmt_date)}
    for item in resolutions:
        if not isinstance(item, dict):
            raise ValueError(f"resolution must be an object: {item!r}")
        action = str(item.get("action") or "").lower()
        line = item.get("line")
        if line is not None:
            line = int(line)
            if not 1 <= line <= line_count:
                raise ValueError(f"line {line} is out of range (1–{line_count})")
            key = str(line)
            for bucket in ("forced", "ignored", "additions"):
                r[bucket].pop(key, None)
            if action == "auto":
                continue
            if action == "ignore":
                r["ignored"][key] = str(item.get("reason") or "set aside by treasurer")
            elif action == "add":
                r["additions"][key] = {k: item[k] for k in ("payee", "category", "memo", "reason", "date",
                                                            "direction", "amount", "check_number") if k in item}
            elif item.get("transaction_id"):
                tid = str(item["transaction_id"]).lower()
                if tid not in eligible_ids:
                    raise ValueError(f"{tid} is not an uncleared transaction on this account dated on or before "
                                     f"{stmt_date}; it cannot be cleared by this statement")
                clash = next((k for k, v in r["forced"].items() if v == tid), None)
                if clash:
                    raise ValueError(f"{tid} is already assigned to line {clash}; free it first with action 'auto'")
                r["forced"][key] = tid
            else:
                raise ValueError(f"line {line}: need a transaction_id or an action (add/ignore/auto)")
        elif item.get("transaction_id"):
            tid = str(item["transaction_id"]).lower()
            if action in ("void", "duplicate", "error", "note"):
                r["ledger_notes"][tid] = {"action": action, "note": str(item.get("note") or "")}
            elif action == "auto":
                r["ledger_notes"].pop(tid, None)
            else:
                raise ValueError(f"{tid}: action must be void, duplicate, error, note, or auto")
        else:
            raise ValueError(f"resolution needs a line or a transaction_id: {item!r}")
    save_session(data)
    res = compute(data)
    res["status"] = "ok"
    return dump(res)


@mcp.tool()
def reconciliation_report(session: str, write_files: bool = True) -> str:
    """Produce the reconciliation report (Markdown) and the JSON plan for a session.

    The report lists the balance arithmetic, items to clear, everything still needing
    manual review, adjustments to enter, and outstanding items carried forward. With
    `write_files` both are saved next to the session file and the paths are appended.
    The ledger itself is never modified: the treasurer applies the plan in TroopLedger
    (Reconcile → Import Plan…), which previews and re-validates it first.
    """
    data = load_session(session)
    res = compute(data)
    report = render_report(res, load_profile(), date.today())
    if write_files:
        base = Path(data["_path"]).with_suffix("")
        md_path = base.with_name(base.name + " report.md")
        plan_path = base.with_name(base.name + ".plan.json")
        RECON_DIR.mkdir(parents=True, exist_ok=True)
        md_path.write_text(report)
        plan_path.write_text(json.dumps(render_plan(res, data), indent=1))
        report += f"\n\n---\nReport: {md_path}\nPlan: {plan_path}\n"
    return report


@mcp.tool()
def list_sessions() -> str:
    """List reconciliation sessions (in-progress and finished) with their status."""
    if not RECON_DIR.exists():
        return dump([])
    out = []
    for p in sorted(RECON_DIR.glob("*.json")):
        if p.name.endswith(".plan.json"):
            continue
        try:
            d = json.loads(p.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        r = d.get("resolutions", {})
        out.append({"session": str(p), "account": d.get("account_name"), "statement_date": d.get("statement_date"),
                    "ending_balance": money(d.get("ending_cents", 0)), "lines": len(d.get("lines", [])),
                    "decisions": sum(len(r.get(k, {})) for k in ("forced", "ignored", "additions", "ledger_notes")),
                    "report": str(p.with_name(p.stem + " report.md")) if p.with_name(p.stem + " report.md").exists() else None,
                    "created_at": d.get("created_at")})
    return dump(out)


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------

@mcp.prompt()
def reconcile_statement(statement: str = "", account: str = "") -> str:
    """Step-by-step guidance for reconciling a bank statement against TroopLedger."""
    where = f"The statement is: {statement}." if statement else "Ask which statement (PDF path or DEVONthink record) to use."
    acct = f"Account: {account}." if account else "Use the default checking account unless told otherwise."
    return f"""You are helping the troop treasurer reconcile a bank statement against TroopLedger. {where} {acct}

1. Call `reconciliation_status` to learn the lock date, the previous statement's ending balance, and how many
   uncleared items exist. The new statement must start where the last reconciliation ended.
2. Read the statement PDF (Read tool, DEVONthink `get_record_text`, or `read_statement_pdf`). Transcribe EVERY
   transaction line — checks, deposits, electronic debits/credits, fees, interest — as
   {{"date","description","amount"}} with signed amounts (deposits positive, withdrawals negative). Note the
   beginning balance, ending balance, and statement date. Do not include balance rows as lines.
3. Call `match_statement` with the lines plus beginning and ending balances. If it reports the statement does not
   foot, re-read the PDF and fix the transcription before continuing — never adjust numbers to force it.
4. Present the result to the treasurer: how many items matched confidently, then each item in `ambiguous`,
   `amount_mismatches`, and `unmatched_lines` with the candidates and your recommendation. Ask them to decide.
   Use `search_transactions` / `register` to chase anything puzzling. Record decisions with `resolve_items`.
5. When nothing is left to review (or the treasurer chooses to leave items open), call `reconciliation_report`.
   Summarise it: does it tie after adjustments, what must be entered in TroopLedger, what is carried forward,
   and anything flagged (stale checks, missing deposits).
6. Remind the treasurer that the ledger was not changed: they apply the `.plan.json` in TroopLedger via
   Reconcile → Import Plan… (which previews and re-validates everything before locking the period), or finish by
   hand using the report's *Items to clear* list.
"""


if __name__ == "__main__":
    mcp.run()
