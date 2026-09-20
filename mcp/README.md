# TroopLedger MCP server

A read-only [MCP](https://modelcontextprotocol.io) server that lets an AI assistant
query the TroopLedger ledger and reconcile bank statements against it.

The ledger is never written. TroopLedger's store is CloudKit-synced SwiftData; edits
made from outside the app would bypass SwiftData's change tracking (never sync, and
could corrupt the store). Every query runs against a throwaway copy of the store, and
the reconciliation produces a **report** and a **plan file** that the treasurer applies
inside TroopLedger's Reconcile screen.

## Setup

```bash
/opt/homebrew/bin/python3 -m pip install -r mcp/requirements.txt
claude mcp add --scope user troopledger -- /opt/homebrew/bin/python3 "/Users/<you>/Documents/xcode projects/TroopLedger/mcp/troopledger_mcp.py"
```

Environment variables (optional):

| Variable | Purpose | Default |
|---|---|---|
| `TROOPLEDGER_STORE` | Path to a `TroopLedger.store` (tests / a copy) | the app's sandbox container |
| `TROOPLEDGER_RECON_DIR` | Where sessions, reports and plans are written | `~/Documents/TroopLedger Reconciliations` |

## Tools

Ledger reads:

- `list_accounts` — accounts with opening/book/cleared balances and lock dates
- `reconciliation_status(account)` — last reconciliation, lock date, uncleared items, suggested next statement date
- `uncleared_transactions(account, through)` — exactly what the app's Reconcile screen offers for a statement date
- `register(account, start, end, include_cleared, limit)` — register with running balance
- `search_transactions(text, amount, check_number, start, end, account, limit)`

Reconciliation:

- `read_statement_pdf(path)` — text layer of a PDF (needs `pypdf`; scanned statements need OCR first)
- `match_statement(statement_date, ending_balance, lines, account, beginning_balance, period_start, notes)` —
  proves the transcription foots, matches lines to uncleared transactions, flags ambiguous / unmatched /
  discrepant items, proposes adjustments, and saves a session
- `resolve_items(session, resolutions)` — records the treasurer's decisions and re-runs the match
- `reconciliation_report(session)` — writes `<Account> <date> report.md` and `<Account> <date>.plan.json`
- `list_sessions()`

Prompt: `reconcile_statement` walks the assistant through the whole flow.

## Workflow

1. **Transcribe.** The assistant reads the statement PDF (Claude's Read tool, DEVONthink
   `get_record_text`, or `read_statement_pdf`) and produces one line per transaction:
   `{"date": "2026-03-31", "description": "CHECK 129", "amount": -118.75}` — signed amounts,
   deposits positive. Fees and interest included; balance rows excluded.
2. **Match.** `match_statement` refuses to proceed if beginning + lines ≠ ending (a misread digit),
   then matches each line one-to-one against the uncleared transactions dated on or before the
   statement date — the same eligibility rule as `ReconciliationPolicy.isEligible` in the app.
3. **Review.** Ambiguous matches (rival candidates or a weak score), amount discrepancies (same
   check number, different amount), and statement lines with no ledger entry are listed with
   context; the treasurer decides and the assistant records it with `resolve_items`.
4. **Report.** `reconciliation_report` produces the balance arithmetic (does it tie once the
   adjustments are entered?), items to clear, adjustments to enter, and outstanding items carried
   forward (stale checks and missing deposits flagged). The plan file lists transaction IDs to
   clear and transactions to add.
5. **Apply in TroopLedger.** Reconcile → **Import Plan…** → choose the `.plan.json`. The app re-checks every
   transaction ID against the live ledger, shows the balance math and any problems or tentative matches, and
   on **Apply Plan** adds the adjustments, clears the items, writes the audit trail, and locks the period —
   through the same `ReconciliationCompletionService` the manual Finish button uses. (The report also has
   by-hand steps.)

## Matching rules

A statement line and a ledger transaction are candidates when the amounts are equal (or the
check numbers agree, which surfaces amount discrepancies). Score: amount 100, check number 60,
date proximity up to 30 (penalised when the bank clears something long before the ledger date),
payee word overlap up to 20. Assignment is one-to-one, best score first. A match is flagged when
another unassigned transaction scores within 15 points or the score is below 120. Identical
deposits on the same day are interchangeable and are not flagged.

## Tests

```bash
cd mcp && /opt/homebrew/bin/python3 -m unittest test_troopledger_mcp -v
```

The suite includes an end-to-end run against a synthetic SwiftData-shaped SQLite store; no real
ledger data is used or committed.
