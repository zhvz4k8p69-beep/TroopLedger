# Workbook import report

## Source and integrity

- Source: `Troop Finance_Spreadsheet 2019.xlsx`
- SHA-256: `bcfb2f06f74e722b407bd28a4a3cdd298cfe28526a96fdbd3c45bb2983ae5057`
- Original workbook modified: no
- Import format: version 1 bundled JSON snapshot
- Total normalized records: 649

## Imported records

| Record | Count | Treatment |
|---|---:|---|
| Account | 1 | Checking account and workbook opening balance |
| Checking transactions | 228 | Authoritative bank-register deposits and expenses |
| Cash receipts | 26 | Supporting Cash Register detail; excluded from bank balance |
| People | 34 | Canonical Scout and leader records |
| Annual registrations | 97 | Historical annual registration rows |
| Current member-ledger entries | 27 | Charges, payments, and balance adjustments reconstructed from paired rows |
| Events | 24 | One event per historical event worksheet |
| Event financial lines | 212 | Actual/projected worksheet detail; excluded from bank balance |

## Verification performed

- The imported checking account independently recalculates to **$836.38**.
- That value matches the workbook's ending checking-register balance.
- The snapshot contains no normalization exceptions.
- All imported enum values map to supported app values.
- A unit test loads and imports all 649 records into a fresh in-memory SwiftData store, verifies the table counts and checking balance, and confirms that a second import of the same fingerprint is rejected.

## Deliberate safeguards

- Import runs only after the user selects the Import action and confirms it.
- The workbook fingerprint prevents the same snapshot from being imported twice on a single synchronized database.
- The UI advises importing on only one device and waiting for iCloud synchronization.
- Cash Register and event-detail lines remain separate from checking transactions to avoid double-counting.
- Source sheet and row references are stored on applicable records.

## Items to review after import

1. Confirm the exact start and end dates of events marked Approximate. Most event sheets stored only a month and year, so the imported placeholder is the first day of that month.
2. Reconcile the checking account to the next available bank statement.
3. Review renamed or historical people and mark inactive records as needed.
4. Confirm the troop's reporting year and category policy before relying on annual committee reports.
5. Keep the original workbook as a read-only audit source until the first app-based reconciliation is complete.
