#!/usr/bin/env python3
"""Tests for the TroopLedger MCP server. Pure matcher tests plus an end-to-end run
against a synthetic store shaped like SwiftData's SQLite (no real ledger data).

    /opt/homebrew/bin/python3 -m unittest mcp/test_troopledger_mcp.py -v
"""

import json
import shutil
import sqlite3
import tempfile
import unittest
import uuid
from datetime import date, datetime, timezone
from pathlib import Path

import troopledger_mcp as m


def L(index, d, desc, cents, check=""):
    return {"index": index, "date": date.fromisoformat(d), "description": desc, "cents": cents,
            "check_number": check, "kind": m.guess_kind(desc, cents, check)}


def T(d, cents, payee="Payee", check="", cleared=False, tid=None, category="Camping"):
    return {"id": tid or str(uuid.uuid4()), "account_id": "A", "date": date.fromisoformat(d), "cents": cents,
            "direction": "Income" if cents > 0 else "Expense", "check_number": m.digits_only(check),
            "reference": check, "payee": payee, "category": category, "memo": "", "is_cleared": cleared,
            "reconciled_at": None, "reconciliation_id": "", "is_adjustment": False, "is_transfer": False,
            "is_deposit_batch": False}


class ConversionTests(unittest.TestCase):
    def test_to_cents(self):
        self.assertEqual(m.to_cents("1,234.56"), 123456)
        self.assertEqual(m.to_cents("(12.34)"), -1234)
        self.assertEqual(m.to_cents("$5"), 500)
        self.assertEqual(m.to_cents(-118.75), -11875)
        self.assertEqual(m.to_cents(7), 700)
        self.assertEqual(m.to_cents("12.345"), 1235)   # half-up, no float drift
        self.assertEqual(m.to_cents("100.00-"), -10000)
        with self.assertRaises(ValueError):
            m.to_cents("abc")

    def test_parse_date(self):
        self.assertEqual(m.parse_date("2026-03-31"), date(2026, 3, 31))
        self.assertEqual(m.parse_date("03/31/2026"), date(2026, 3, 31))
        self.assertEqual(m.parse_date("3/31/26"), date(2026, 3, 31))
        self.assertEqual(m.parse_date("3/31", default_year=2026), date(2026, 3, 31))
        with self.assertRaises(ValueError):
            m.parse_date("3/31")

    def test_digits_only(self):
        self.assertEqual(m.digits_only("0131"), "131")
        self.assertEqual(m.digits_only("ACH"), "")
        self.assertEqual(m.digits_only(""), "")


class NormalizeTests(unittest.TestCase):
    def test_lines(self):
        lines = m.normalize_lines([
            {"date": "3/31", "description": "CHECK 0129", "amount": -118.75},
            {"date": "2026-04-01", "description": "DEPOSIT", "credit": "40.00"},
            {"date": "2026-04-02", "description": "MONTHLY SERVICE FEE", "debit": 5},
            {"date": "2026-04-03", "description": "INTEREST PAID", "amount": 0.12},
        ], date(2026, 4, 30))
        self.assertEqual([l["cents"] for l in lines], [-11875, 4000, -500, 12])
        self.assertEqual(lines[0]["check_number"], "129")
        self.assertEqual([l["kind"] for l in lines], ["check", "deposit", "fee", "interest"])
        self.assertEqual(lines[0]["date"], date(2026, 3, 31))

    def test_rejects_zero_and_bad_input(self):
        with self.assertRaises(ValueError):
            m.normalize_lines([{"date": "2026-01-01", "description": "x", "amount": 0}], date(2026, 1, 31))
        with self.assertRaises(ValueError):
            m.normalize_lines([], date(2026, 1, 31))
        with self.assertRaises(ValueError):
            m.normalize_lines([{"date": "yesterday", "description": "x", "amount": 1}], date(2026, 1, 31))


class ScoreTests(unittest.TestCase):
    def test_exact_same_day_is_confident(self):
        s = m.score_pair(L(1, "2026-03-05", "DEPOSIT", 4000), T("2026-03-05", 4000, "Deposit"))
        self.assertGreaterEqual(s["score"], m.CONFIDENT_SCORE)

    def test_check_number_conflict_disqualifies(self):
        self.assertIsNone(m.score_pair(L(1, "2026-03-05", "CHECK 130", -5000, "130"), T("2026-03-05", -5000, check="131")))

    def test_sign_mismatch_disqualifies(self):
        self.assertIsNone(m.score_pair(L(1, "2026-03-05", "CHECK 130", -5000, "130"), T("2026-03-05", 5000, check="130")))

    def test_amount_mismatch_with_check_is_candidate(self):
        s = m.score_pair(L(1, "2026-03-05", "CHECK 130", -5900, "130"), T("2026-03-01", -5000, check="130"))
        self.assertIsNotNone(s)
        self.assertFalse(s["amount_exact"])
        self.assertTrue(s["check_equal"])

    def test_bank_long_before_ledger_is_penalised(self):
        early = m.score_pair(L(1, "2026-03-01", "ACH", -5000), T("2026-03-20", -5000))
        same = m.score_pair(L(1, "2026-03-20", "ACH", -5000), T("2026-03-20", -5000))
        self.assertLess(early["score"], same["score"])

    def test_payee_similarity(self):
        with_payee = m.score_pair(L(1, "2026-03-05", "ACH DEBIT MAYFLOWER COUNCIL", -5000), T("2026-03-05", -5000, "Mayflower Council"))
        without = m.score_pair(L(1, "2026-03-05", "ACH DEBIT", -5000), T("2026-03-05", -5000, "Mayflower Council"))
        self.assertGreater(with_payee["score"], without["score"])


class MatchingTests(unittest.TestCase):
    def test_identical_deposits_same_day_are_not_ambiguous(self):
        eligible = [T("2026-03-05", 1875, "Deposit"), T("2026-03-05", 1875, "Deposit")]
        lines = [L(1, "2026-03-05", "DEPOSIT", 1875), L(2, "2026-03-05", "DEPOSIT", 1875)]
        r = m.run_matching(lines, eligible, [])
        self.assertEqual(len(r["matched"]), 2)
        self.assertEqual(r["ambiguous"], [])
        self.assertEqual(r["outstanding"], [])

    def test_spare_candidate_makes_line_ambiguous(self):
        eligible = [T("2026-03-05", 12000, "Deposit"), T("2026-02-20", 12000, "Deposit")]
        r = m.run_matching([L(1, "2026-03-06", "DEPOSIT", 12000)], eligible, [])
        self.assertEqual(len(r["ambiguous"]), 1)
        cands = r["ambiguous"][0]["candidates"]
        self.assertEqual(len(cands), 2)
        self.assertTrue(cands[0]["tentative"])
        self.assertEqual(cands[0]["date"], "2026-03-05")
        self.assertEqual(len(r["outstanding"]), 1)

    def test_forced_resolution_overrides_and_frees_rival(self):
        older = T("2026-02-20", 12000, "Deposit", tid="older")
        newer = T("2026-03-05", 12000, "Deposit", tid="newer")
        r = m.run_matching([L(1, "2026-03-06", "DEPOSIT", 12000)], [older, newer], [],
                           {"forced": {"1": "older"}})
        self.assertEqual(r["matched"][0]["ledger"]["transaction_id"], "older")
        self.assertEqual(r["matched"][0]["reasons"][0], "resolved manually")
        self.assertEqual([o["transaction_id"] for o in r["outstanding"]], ["newer"])

    def test_check_number_wins_over_date(self):
        a = T("2026-03-01", -5000, "A", check="130", tid="a")
        b = T("2026-03-20", -5000, "B", check="131", tid="b")
        r = m.run_matching([L(1, "2026-03-21", "CHECK 130", -5000, "130")], [a, b], [])
        self.assertEqual(r["matched"][0]["ledger"]["transaction_id"], "a")
        self.assertEqual(r["ambiguous"], [])   # b is disqualified by its check number, not a rival

    def test_amount_mismatch_bucket(self):
        t = T("2026-03-01", -5000, "A", check="130", tid="a")
        r = m.run_matching([L(1, "2026-03-04", "CHECK 130", -5900, "130")], [t], [])
        self.assertEqual(len(r["amount_mismatches"]), 1)
        self.assertEqual(r["amount_mismatches"][0]["difference_cents"], -900)
        self.assertEqual(r["matched"], [])

    def test_unmatched_line_shows_context(self):
        cleared = [T("2026-02-25", -5000, "Old", check="120", cleared=True)]
        near = T("2026-03-04", -5090, "Near", tid="near")
        r = m.run_matching([L(1, "2026-03-05", "CHECK 120", -5000, "120"),
                            L(2, "2026-03-31", "MONTHLY SERVICE FEE", -500)], [near], cleared)
        self.assertEqual(len(r["unmatched_lines"]), 2)
        first, fee = r["unmatched_lines"]
        self.assertEqual(first["kind"], "missing_from_ledger")
        self.assertEqual(len(first["already_cleared_candidates"]), 1)
        self.assertEqual([n["transaction_id"] for n in first["near_misses"]], ["near"])
        self.assertEqual(fee["kind"], "bank_fee")

    def test_ignored_and_added_lines(self):
        r = m.run_matching([L(1, "2026-03-05", "DUPLICATE", 100), L(2, "2026-03-06", "FEE", -500)], [], [],
                           {"ignored": {"1": "printed twice"}, "additions": {"2": {"payee": "Bank"}}})
        self.assertEqual(r["ignored_lines"][0]["reason"], "printed twice")
        self.assertEqual(r["additions"][0]["add"]["payee"], "Bank")
        self.assertEqual(r["unmatched_lines"], [])


class ClassifyTests(unittest.TestCase):
    def view(self, t):
        return {"transaction_id": t["id"], "date": t["date"].isoformat(), "cents": t["cents"],
                "check_number": t["reference"], "payee": t["payee"], "ledger_note": None}

    def test_statuses(self):
        stmt = date(2026, 3, 31)
        items = [self.view(T("2026-03-29", 4000)),                    # in transit
                 self.view(T("2026-03-10", 4000)),                    # missing deposit
                 self.view(T("2026-03-20", -5000, check="140")),      # outstanding check
                 self.view(T("2025-11-01", -5000, check="101")),      # stale check
                 self.view(T("2026-02-10", 2000)),                    # prior-period deposit
                 self.view(T("2026-03-20", -7500, "ACH"))]            # electronic debit not posted
        m.classify_outstanding(items, date(2026, 3, 1), stmt)
        self.assertEqual([i["status"] for i in items],
                         ["deposit_in_transit", "missing_deposit", "outstanding_check", "prior_period_check",
                          "prior_period_deposit", "outstanding_debit"])
        self.assertEqual([i["attention"] for i in items], [False, True, False, True, False, True])

    def test_treasurer_note(self):
        item = self.view(T("2026-03-20", -5000, check="140"))
        item["ledger_note"] = {"action": "void", "note": "reissued as #150"}
        m.classify_outstanding([item], None, date(2026, 3, 31))
        self.assertEqual(item["status"], "void")
        self.assertIn("reissued", item["flag"])


class CategoryTests(unittest.TestCase):
    CATS = [{"name": n, "direction": d, "is_active": True} for n, d in
            [("Registration Fees", "Income"), ("Interest", "Income"), ("Bank Fees", "Expense"), ("Other Expense", "Expense")]]

    def test_bank_fee_prefers_bank_category(self):
        self.assertEqual(m.suggest_category("bank_fee", self.CATS, "Expense"), "Bank Fees")

    def test_interest(self):
        self.assertEqual(m.suggest_category("interest", self.CATS, "Income"), "Interest")

    def test_unknown_stays_uncategorized(self):
        self.assertEqual(m.suggest_category("missing_from_ledger", self.CATS, "Expense"), "Uncategorized")


# ---------------------------------------------------------------------------
# End to end against a synthetic SwiftData-shaped store
# ---------------------------------------------------------------------------

def cd_ts(d: date) -> float:
    return datetime(d.year, d.month, d.day, 12, tzinfo=timezone.utc).timestamp() - m.CORE_DATA_EPOCH


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="tl-test-"))
        cls.store = cls.tmp / "TroopLedger.store"
        cls.account = uuid.uuid4()
        conn = sqlite3.connect(cls.store)
        conn.executescript("""
            CREATE TABLE ZACCOUNTRECORD (Z_PK INTEGER PRIMARY KEY, ZISACTIVE INTEGER, ZOPENINGBALANCECENTS INTEGER,
                ZINSTITUTION VARCHAR, ZKINDRAW VARCHAR, ZNAME VARCHAR, ZNOTES VARCHAR, ZID BLOB);
            CREATE TABLE ZLEDGERTRANSACTION (Z_PK INTEGER PRIMARY KEY, ZAMOUNTCENTS INTEGER, ZISCLEARED INTEGER,
                ZDATE TIMESTAMP, ZRECONCILEDAT TIMESTAMP, ZCATEGORY VARCHAR, ZCHECKNUMBER VARCHAR, ZDIRECTIONRAW VARCHAR,
                ZMEMO VARCHAR, ZPAYEE VARCHAR, ZACCOUNTID BLOB, ZEVENTID BLOB, ZID BLOB, ZPERSONID BLOB,
                ZRECONCILIATIONID BLOB, ZISADJUSTMENT INTEGER, ZISTRANSFER INTEGER, ZDEPOSITBATCHID BLOB);
            CREATE TABLE ZRECONCILIATIONRECORD (Z_PK INTEGER PRIMARY KEY, ZCLEAREDBALANCECENTS INTEGER,
                ZSTATEMENTENDINGBALANCECENTS INTEGER, ZCOMPLETEDAT TIMESTAMP, ZSTATEMENTDATE TIMESTAMP, ZNOTES VARCHAR,
                ZACCOUNTID BLOB, ZID BLOB);
            CREATE TABLE ZLEDGERCATEGORYRECORD (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZDIRECTIONRAW VARCHAR,
                ZISACTIVE INTEGER, ZSORTORDER INTEGER);
            CREATE TABLE ZTROOPPROFILERECORD (Z_PK INTEGER PRIMARY KEY, ZTROOPNAME VARCHAR, ZTROOPNUMBER VARCHAR,
                ZCOUNCIL VARCHAR, ZTREASURERNAME VARCHAR, ZCHARTEREDORGANIZATION VARCHAR);
        """)
        conn.execute("INSERT INTO ZACCOUNTRECORD VALUES (1,1,10000,'Test Bank','Checking','Checking Account','',?)",
                     (cls.account.bytes,))
        conn.execute("INSERT INTO ZLEDGERCATEGORYRECORD VALUES (1,'Bank Fees','Expense',1,1),(2,'Interest','Income',1,2)")
        conn.execute("INSERT INTO ZTROOPPROFILERECORD VALUES (1,'Troop 99','99','Test Council','Pat','')")
        # Previous reconciliation through Jan 31 locked the account with cleared balance $150.
        conn.execute("INSERT INTO ZRECONCILIATIONRECORD VALUES (1,15000,15000,?,?,'',?,?)",
                     (cd_ts(date(2026, 2, 3)), cd_ts(date(2026, 1, 31)), cls.account.bytes, uuid.uuid4().bytes))
        cls.ids = {}
        rows = [  # key, date, direction, cents, check, payee, cleared
            ("jan_dep", date(2026, 1, 10), "Income", 5000, "DEP", "Deposit", 1),
            ("feb_dep1", date(2026, 2, 3), "Income", 4000, "DEP", "Deposit", 0),
            ("feb_dep2", date(2026, 2, 3), "Income", 4000, "DEP", "Deposit", 0),
            ("chk_201", date(2026, 2, 10), "Expense", 10812, "201", "Camp Supplier", 0),
            ("chk_202", date(2026, 2, 17), "Expense", 1272, "202", "Scout Shop", 0),
            ("ach", date(2026, 2, 20), "Expense", 2500, "ACH", "Council", 0),
            ("late_dep", date(2026, 2, 27), "Income", 2000, "DEP", "Deposit", 0),
            ("march", date(2026, 3, 2), "Expense", 999, "203", "Future", 0),
        ]
        for pk, (key, d, direction, cents, check, payee, cleared) in enumerate(rows, start=1):
            tid = uuid.uuid4()
            cls.ids[key] = str(tid)
            conn.execute("INSERT INTO ZLEDGERTRANSACTION VALUES (?,?,?,?,NULL,'Camping',?,?,'',?,?,NULL,?,NULL,NULL,0,0,NULL)",
                         (pk, cents, cleared, cd_ts(d), check, direction, payee, cls.account.bytes, tid.bytes))
        conn.commit()
        conn.close()
        m.STORE_OVERRIDE = str(cls.store)
        m.RECON_DIR = cls.tmp / "recon"
        m._discard_snapshot()

    @classmethod
    def tearDownClass(cls):
        m._discard_snapshot()
        m.STORE_OVERRIDE = None
        shutil.rmtree(cls.tmp, ignore_errors=True)

    LINES = [
        {"date": "02/03/2026", "description": "DEPOSIT", "amount": 40.00},
        {"date": "02/04/2026", "description": "DEPOSIT", "amount": 40.00},
        {"date": "02/14/2026", "description": "CHECK 201", "amount": -108.12},
        {"date": "02/21/2026", "description": "CHECK 202", "amount": -21.72},      # ledger says 12.72
        {"date": "02/23/2026", "description": "ACH DEBIT COUNCIL", "amount": -25.00},
        {"date": "02/28/2026", "description": "MONTHLY SERVICE FEE", "amount": -5.00},
    ]
    ENDING = 150.00 + 40 + 40 - 108.12 - 21.72 - 25 - 5

    def test_status_and_uncleared(self):
        st = json.loads(m.reconciliation_status())
        self.assertEqual(st["locked_through"], "2026-01-31")
        self.assertEqual(st["cleared_balance_today"], "$150.00")
        u = json.loads(m.uncleared_transactions(through="2026-02-28"))
        self.assertEqual(u["count"], 6)   # March item excluded
        self.assertNotIn(self.ids["march"], [t["transaction_id"] for t in u["transactions"]])

    def test_rejects_locked_and_future_dates(self):
        with self.assertRaises(ValueError):
            m.match_statement("2026-01-31", "150.00", self.LINES)
        with self.assertRaises(ValueError):
            m.match_statement("2099-01-31", "150.00", self.LINES)

    def test_foot_failure(self):
        r = json.loads(m.match_statement("2026-02-28", self.ENDING + 40, self.LINES, beginning_balance="150.00"))
        self.assertEqual(r["status"], "statement_does_not_foot")
        self.assertEqual(r["off_by"], "$40.00")
        self.assertFalse((m.RECON_DIR / "Checking Account 2026-02-28.json").exists())

    def test_full_flow(self):
        r = json.loads(m.match_statement("2026-02-28", self.ENDING, self.LINES, beginning_balance="150.00"))
        self.assertEqual(r["status"], "ok")
        self.assertTrue(r["statement"]["foot"]["foots"])
        self.assertTrue(r["statement"]["beginning_balance_check"]["agrees"])
        self.assertEqual(r["counts"]["matched"], 4)          # two deposits, check 201, ACH
        self.assertEqual(r["counts"]["amount_mismatches"], 1)
        self.assertEqual(r["counts"]["unmatched_lines"], 1)  # the fee
        self.assertEqual(r["unmatched_lines"][0]["kind"], "bank_fee")
        self.assertEqual([o["status"] for o in r["outstanding"]], ["deposit_in_transit"])
        self.assertTrue(r["balances"]["ties_after_adjustments"])
        adj = {p["payee"]: p for p in r["proposed_adjustments"]}
        self.assertEqual(adj["MONTHLY SERVICE FEE"]["category"], "Bank Fees")
        self.assertEqual(adj["Scout Shop"]["amount_cents"], 900)
        self.assertEqual(adj["Scout Shop"]["adjusts_transaction_id"], self.ids["chk_202"])

        r2 = json.loads(m.resolve_items(r["session"], [
            {"line": 6, "action": "add", "payee": "Test Bank", "category": "Bank Fees"},
            {"transaction_id": self.ids["late_dep"], "action": "note", "note": "deposited 2/27 after cutoff"},
        ]))
        self.assertEqual(r2["counts"]["additions"], 1)
        self.assertEqual(r2["counts"]["unmatched_lines"], 0)
        self.assertEqual(r2["balances"]["accepted_adjustments_net"], "-$5.00")
        self.assertIn("deposited 2/27", r2["outstanding"][0]["flag"])
        with self.assertRaises(ValueError):
            m.resolve_items(r["session"], [{"line": 1, "transaction_id": self.ids["march"]}])
        with self.assertRaises(ValueError):   # already forced elsewhere
            m.resolve_items(r["session"], [{"line": 1, "transaction_id": self.ids["feb_dep1"]},
                                           {"line": 2, "transaction_id": self.ids["feb_dep1"]}])

        report = m.reconciliation_report(r["session"])
        self.assertIn("Troop 99", report)
        self.assertIn("✅ ties", report)
        self.assertIn("Test Bank", report)
        plan = json.loads((m.RECON_DIR / "Checking Account 2026-02-28.plan.json").read_text())
        self.assertEqual(plan["format"], m.PLAN_FORMAT)
        self.assertEqual(len(plan["clear_transaction_ids"]), 5)
        self.assertEqual(plan["tentative_transaction_ids"], [self.ids["chk_202"]])
        self.assertEqual({a["status"] for a in plan["add_transactions"]}, {"accepted", "proposed"})
        sessions = json.loads(m.list_sessions())
        self.assertEqual(sessions[0]["statement_date"], "2026-02-28")
        self.assertIsNotNone(sessions[0]["report"])

    def test_snapshot_rejects_foreign_store(self):
        other = self.tmp / "other.store"
        sqlite3.connect(other).execute("CREATE TABLE ZSOMETHING (x)").connection.commit()
        saved = m.STORE_OVERRIDE
        m.STORE_OVERRIDE = str(other)
        m._discard_snapshot()
        try:
            with self.assertRaises(sqlite3.DatabaseError):
                m.snapshot()
        finally:
            m.STORE_OVERRIDE = saved
            m._discard_snapshot()


if __name__ == "__main__":
    unittest.main()
