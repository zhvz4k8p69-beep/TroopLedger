# TroopLedger

TroopLedger 1.0 is a SwiftUI finance system of record for one Scouting America troop and one treasurer. It runs from one shared codebase on iPhone, iPad, and Mac, stores data with SwiftData, and is configured for private CloudKit sync across the treasurer's own devices.

## Included in version 1.0

- Multiple checking, savings, Cash on Hand, or other accounts plus one distinct Undeposited Funds holding account
- Check-register-style income and expense entry with check/reference numbers, clearing status, categories, memos, and links to people or events
- Transaction-register rows display the complete memo beneath their date, category, and account details
- Scout, leader, parent/guardian, and other person records
- Combined status and role filters in the People list: Active/Inactive/All plus Scouts, Leaders, Parents/Guardians, Other, or All Roles
- Current Scouts BSA rank, multiple youth or adult troop positions, and a custom troop-specific position on every person record
- Official rank and position presets, including all seven Scouts BSA ranks, 17 youth leadership positions, and 13 adult troop/committee positions
- Annual registration history and dues assessed
- A separate member ledger for charges, payments, credits, and adjustments
- Family grouping that reuses existing person records, with combined PDF statements showing period activity, current amount due or credit, and future-dated charges through the system export sheet
- Reviewed charge batches for recurring dues and registration assessments, with per-person previews, immutable allocation history, and exact duplicate protection
- Event planning with precise timed/all-day schedules, Troop/District/Council/National classification, venue and address details, Apple Maps previews, budgets, participants, fees, payments, transportation notes, and linked actual transactions
- Event rosters with filtered bulk member selection, named non-member guests, attendee status editing, Scout/adult grouping, and native printing with check-in/check-out boxes
- Event fee planning with explicit fixed/per-person costs, attendance and contingency assumptions, break-even and rounded suggested fees, multiple named fee schedules, and council or venue confirmation references
- Duplicate-safe event close-out with immutable roster allocations, actual per-participant cost, unpaid/refund-due totals, final variance, and optional final member-ledger adjustments
- Calendar and list views for all events, with multi-day event coverage and approximate-date warnings
- Editable multiline notes on every event detail screen
- A verified, fingerprint-protected starting-data import for `Troop Finance_Spreadsheet 2019.xlsx`
- Previewed CSV/TSV imports from Scoutbook Plus Quick Export for Scouts/Members, Leaders & Parents, and Payment Log data
- General transaction-register CSV/TSV import with account selection, field mapping, a no-write preview, row-level exception review, locked-period validation, and exact-file duplicate protection
- Duplicate protection for both complete Scoutbook export files and individual payment rows
- Read-only Scoutbook iCalendar (`.ics`) subscriptions that appear in the app's event calendar and can be refreshed manually
- The supplied Troop Ledger artwork configured as the app icon on iPhone, iPad, and Mac
- Separate imported cash-receipt and event-detail records so workbook detail does not double-count the checking account
- Checking-account reconciliation against statement ending balances
- Reconciled-period locking that makes historical transactions read-only and routes corrections through dated, linked adjusting entries with required explanations
- Reimbursement requests with requester, purpose, expense category, event link, image/PDF receipts, review decisions, payment recording, and one-to-one ledger transaction linkage
- Optional, configurable dual-control evidence for reimbursements, with historical approver and signer identity snapshots plus advisory same-person, same-household, and missing-evidence warnings
- Reimbursement approval exception reporting for missing receipts, review metadata, configured signer controls, and linked payments, with an audited approval-and-audit CSV export
- A duplicate-safe Undeposited Funds account for cash and checks awaiting deposit, reported separately from bank accounts and Cash on Hand
- An audited batch deposit builder that combines Undeposited Funds transactions and imported cash receipts into one bank deposit while preserving every payer, person, event, purpose, and amount allocation
- A searchable, read-only Audit Log recording manual creation, edits and deletions; imports; calendar sync; reconciliation and locking; and adjustments with timestamps and available device/user identity
- A full plaintext backup for independent safekeeping and treasurer handoff, containing complete JSON, normalized CSV tables, the audit log, import history, and an attachment manifest
- September-through-August school-year income/expense reports by category, with calendar-year reporting retained as an alternate view
- A reusable standard category catalog supplemented by categories already present in the register
- School-year working budgets, dated approved revisions, and budget-to-actual variance including unbudgeted activity
- Current account and member balance reports
- Recharter cash forecasting with visible active-person, registration-cost, unit-charter, other-cost, expected-collection, and assessed-dues assumptions
- Dated monthly treasurer PDFs plus fingerprinted committee PDF/CSV packages with portable registers and budget variance
- Self-contained annual audit and treasurer-turnover packages containing period reports and the full plaintext data/attachment handoff with a SHA-256 manifest
- A dashboard with balances, uncleared transactions, member balances, and upcoming events

Money is stored as integer cents, avoiding the rounding problems that can occur when currency is stored as floating-point values.

Audit logging begins when version 0.6 or later is used. TroopLedger does not manufacture retrospective entries for changes made by older versions; existing source-sheet, source-row, import-history, and reconciliation metadata remains available for that earlier history.

## Device lock

Open **Preferences → Controls → Device Access** to require Face ID, Touch ID, or the device passcode whenever TroopLedger returns to the foreground. The lock is off by default and only affects the device where it is enabled; the shared database is not changed.

## Plaintext backup

Open **Reports** and select **Export Full Plaintext Backup**. TroopLedger creates a dated `.troopledgerbackup` package that can be copied independently of iCloud. On a Mac, use **Show Package Contents** to inspect `backup.json`, the normalized CSV files, `attachments_manifest.csv`, and `README.txt`.

The JSON and CSV files cover every persisted record type and preserve UUID relationships. Dates are UTC ISO 8601 values and money is integer cents. Exports are recorded in the Audit Log after the system confirms that the package was saved. Reimbursement receipts are copied beneath the backup’s `attachments` directory; `attachments_manifest.csv` records each owning request, relative path, media type, byte count, and SHA-256 checksum.

Version 0.9.1 registers the `com.bettnet.troopledger.backup` package type in both the iPhone/iPad and Mac app metadata, allowing the system exporter to create `.troopledgerbackup` packages without an undeclared-type warning.

The sandboxed Mac app has read/write access only to files the user explicitly selects. This allows the native file picker to open for imports, receipt attachments, reports, family statements, committee snapshots, audit packages, and plaintext backups while leaving all other files outside TroopLedger's sandbox.

Backups contain private financial and contact information, including calendar-subscription URLs. Store and transfer them securely. Version 0.7 exports data for backup and handoff; restoring a backup into the live database is not yet an in-app workflow.

To discard the current database and begin a new setup, open **Preferences → Controls** and use the separate **Start Over** section at the bottom. Export the offered plaintext backup first if the records may be needed later. **Delete All Records and Start Over** warns that the deletion also syncs through iCloud, requires an initial destructive confirmation, and then requires typing `DELETE` before it removes every persisted record, including the troop profile, financial records, people, events, attachments, import history, control settings, and audit log. The first entry written to the fresh audit log records the reset itself, with the device, time, and number of records removed.

## Monthly, committee, and annual reporting

Open **Reports → Monthly & Committee Reports** and select any month. The on-screen summary and exported PDF include opening and ending cash, income and expenses by category, Undeposited Funds, member balances, school-year budget variance through that month, and the latest reconciliation state for each active bank account.

**Export Fingerprinted Committee Snapshot** creates a dated `.troopledgercommittee` package containing the PDF, summary CSV, period register, budget-variance CSV, and a SHA-256 manifest. This is a read-only committee handoff and does not grant access to the live CloudKit database.

Open **Reports → Annual Audit & Turnover Package** to export a school-year `.troopledgeraudit` package. It includes an annual PDF, period register, budget-to-actual and reimbursement-exception CSV files, the complete plaintext backup, reimbursement receipts, event close-outs, reconciliations, member ledgers, audit history, and a SHA-256 manifest. Treat both package types as private financial records.

## Recharter cash forecast

Open **Reports → Recharter Cash Forecast**. Enter the planned per-person registration cost, unit charter cost, other known costs, and collections expected before payment. TroopLedger shows the active-person count, current troop cash, projected cost, projected ending cash, and matching assessed-registration total as a separate reference. Every assumption remains visible; the calculator does not post charges or bank activity.

## Event fee planning and close-out

Open an event and choose **Fee Calculator & Schedules**. Enter fixed costs, per-person costs, expected attendance, and an explicit contingency or margin. TroopLedger shows the exact break-even fee and a suggested fee rounded up to the next dollar. Add any number of named schedules—such as Youth, Adult, or Subsidized—and select the applicable schedule when editing a participant. Event editing also retains a council or venue confirmation number.

Choose **Close Out Event** after attendance and actual financial detail are complete. The preview uses registered, attended, and no-show participants, calculates actual per-participant cost, identifies unpaid and refund-due amounts, and shows each proposed final-cost adjustment. Posting freezes an immutable participant allocation, records final income/expense/variance, marks the event completed, and rejects a second close-out. If **Post final-cost member adjustments** is enabled, TroopLedger creates one linked increase or decrease for each rostered member whose recorded fee differs from actual per-participant cost; guests remain in the frozen allocation without a member-ledger entry.

## Reporting year

Reports default to a 12-month school year beginning September 1 and ending August 31. For example, the **2025–2026 School Year** includes transactions from September 1, 2025 through August 31, 2026. Open **Reports** to select a school year or switch to the retained January-through-December Calendar Year view. The chosen report type is remembered on that device.

TroopLedger intentionally does not offer an arbitrary fiscal-year start month. The troop’s reporting-year decision is September through August; calendar years remain available only as a secondary reporting basis.

## Categories and operating budgets

Open **Budget** to maintain income and expense categories and prepare the operating budget for a September-through-August school year. TroopLedger seeds a standard troop category catalog and adds distinct categories already used by imported or manually entered transactions. Archiving a definition removes it from new choices without rewriting historical records.

Each school year has an editable **Working Budget**. Approving it creates a dated, read-only revision while leaving the working copy available for later planning. **Reports** uses the newest approved revision for that school year, or the working budget when no approval exists. Variance includes actual activity in categories that were not budgeted; a positive value means income exceeded plan or expenses were below plan.

## Reimbursement workflow

Open **Reimbursements** and choose **New Reimbursement**. Select an existing person as the requester, then record the purchase date, business purpose, amount, expense category, optional event, and any notes. After saving, attach image or PDF receipts up to 15 MB each. On iPhone or iPad, **Scan Receipt** uses Apple’s document camera and retains each scanned page; on Mac, choose existing image or PDF files. Exact duplicate receipt data is rejected by SHA-256 fingerprint.

Submitted requests and receipts remain editable until review. **Review Request** records the approver, optional adult roster link and household label, notes, and an approval or decline; declining requires an explanation. Review freezes both the request details and receipt evidence. Approval does not create a bank transaction.

For an approved request, use **Record Control Evidence** to retain an approver and up to two check signers. Role choices link only to adult roster records; each name and household label is also copied into the reimbursement as a historical snapshot so later roster edits do not rewrite old evidence. Household labels are user-entered administrative labels, not contact addresses.

Dual-control tracking is optional. On Mac, open **TroopLedger → Settings** or press **Command-,**. On iPhone or iPad, use the gear button. The master switch hides the dual-control workflow and all of its warnings without deleting previously recorded evidence. The same preferences configure the expected approver and signer count and the same-person, same-household, and missing-household warnings.

Then choose **Record Payment**. You can link an existing unlinked expense with the exact reimbursement amount, or create a new expense with an account, payment date, and check or payment reference. New expenses use the same reconciled-period lock validation as manual ledger entries. Each request links to one expense, and each expense can satisfy only one reimbursement, preventing the reimbursement workflow from double-posting the bank account. Dual-control warnings remain visible but never block payment; TroopLedger records evidence and does not determine legal or organizational compliance.

## Reimbursement approval reporting

Open **Reports → Approval Exceptions & Audit Report** to review incomplete reimbursement workflows. The report groups exceptions into Receipt, Approval, Signer Controls, and Payment Link categories. Submitted requests remain visible as awaiting approval, approved requests remain visible until a matching expense is linked, and paid requests verify that the linked expense still exists and matches the reimbursement amount. Declined requests do not require receipts, signers, or payment links, but must retain their decline review metadata.

Use **Export Approval & Audit CSV** for a complete row-by-row report of every reimbursement. The CSV includes receipt counts, review and historical signer evidence, linked-transaction identifiers, exception details, related audit-entry counts, and the latest audit date. The export itself is added to the Audit Log. When dual-control tracking is disabled in Preferences, signer and approver control warnings are omitted from the report without removing previously recorded evidence.

## Undeposited Funds

Open **Accounts** and choose **Create Undeposited Funds Account** to add the troop’s single holding account for cash and checks that have been received but are not yet included in a bank deposit. You can also select **Undeposited Funds** in the ordinary account editor. TroopLedger prevents a second account of this type, including when the first one is inactive, so historical receipt activity cannot be split accidentally.

Enter received cash and checks against this account rather than Cash on Hand. The dashboard shows the amount awaiting deposit separately. Balance reports show Bank and Cash on Hand, Undeposited Funds, and total troop cash as distinct figures. The account remains part of total cash; only its presentation and operational purpose are separated.

## Batch deposits

Open **Deposits** and choose **New Deposit**. Select any available income transactions already recorded in Undeposited Funds and any imported Cash Receipt rows that belong in the bank deposit. Choose the destination bank account, date, and optional deposit reference, then review the allocation count and total before posting.

Posting retains a read-only allocation for every selected receipt, including its source record, payer-name snapshot, linked person and event when available, purpose, payment type, received date, and amount. Imported Cash Receipt rows are converted into traceable Undeposited Funds income transactions. The app then creates one matched transfer out of Undeposited Funds and one matching deposit into the destination account. Transfers are excluded from income, expense, and budget-variance reports so the original receipts are not counted twice.

Each receipt can belong to only one batch. Posting is blocked if either account is locked for the deposit date, an imported receipt would back-post into a locked holding period, a source was already deposited, or the transfer would make Undeposited Funds negative. Posted receipt and transfer transactions are read-only; batch history retains both transaction links and is included in plaintext backups.

## Family statements

Open **Reports → Create & Export Family Statements**. Create a family and select its members from the existing People records. A person can belong to one family; moving someone to a different family changes only that grouping and never copies or rewrites the person’s member-ledger entries.

Choose the activity beginning date and statement as-of date. The statement shows the balance carried into the period, new charges, payments and credits, signed balance adjustments, the current family balance, a running activity balance, and future-dated charges as upcoming due items. Future charges do not affect the current balance. A positive balance is due to the troop and a negative balance is a family credit.

**Export PDF** opens the native system export sheet on iPhone, iPad, and Mac. The PDF deliberately omits phone numbers, email addresses, Scouting Member IDs, and other unnecessary youth data, but it still contains private family financial information and should be shared securely. Version 0.16 does not send email or deliver statements automatically.

## Recurring dues and registration charges

Open **Charge Batches** and choose **New Charge Batch**. For recurring dues, enter one amount that will apply to each selected person. For registration charges, choose a program year; TroopLedger uses each person’s positive **Dues assessed** amount from the preferred current registration record for that year. People without an assessment for the selected year cannot be included silently.

Selection is a no-write preview. Choose eligible people, then use **Review Charges** to inspect every person and amount plus the batch total. Only **Post Charges** creates records. Posting adds one ordinary member-ledger charge per person, an immutable batch allocation preserving the charged name and amount, and one audited batch-history record. It does not create bank-account income; payments still enter through the existing receipt and member-ledger workflows.

TroopLedger rejects a likely accidental repeat when a prior batch already charged the same person on the same date for the same category and amount. Legitimate subsequent dues use their actual new charge date. Posted batch history is read-only and included in the plaintext backup, and its generated charges automatically appear in family statements.

## Open and run

1. Open `TroopLedger.xcodeproj` in Xcode 26 or later.
2. Choose either the `TroopLedger-iOS` or `TroopLedger-macOS` scheme.
3. In **Signing & Capabilities** for both app targets, select your Apple Developer team.
4. Confirm that the bundle identifier and iCloud container are available to that team.
5. Run on a signed-in iPhone, iPad, or Mac.

The project currently uses:

- Bundle identifier: `com.bettnet.TroopLedger`
- iCloud container: `iCloud.com.bettnet.TroopLedger`
- Minimum iOS/iPadOS: 18.0
- Minimum macOS: 15.0

If the bundle identifier must change, update both app targets and `Configuration/TroopLedger.entitlements`. The two platforms must continue to use the same CloudKit container.

## First-use workflow

For the supplied workbook:

1. Open **Imports** and review the source, verification result, and record counts.
2. Select **Import Workbook Starting Data** on one device only.
3. Let iCloud finish syncing before opening the app on another device.
4. Open **Events** and confirm the exact dates of imported events marked with the orange approximate-date symbol. The workbook usually stored only month and year for these events.
5. Reconcile the imported checking register to the next bank statement before treating the app as authoritative. Completing the reconciliation locks that account through the statement date; later corrections use linked adjusting entries instead of rewriting history.

For a new ledger without the workbook, add the checking account and the Undeposited Funds holding account in **Accounts**, then add people, transactions, member-ledger entries, and events manually.

## Scoutbook Plus workflow

Scoutbook access in version 0.3 uses its user-facing export and calendar-subscription features. It does not call private Scoutbook endpoints, automate a login, or store Scoutbook credentials.

To import a Quick Export:

1. In Scoutbook Plus, create a Quick Export for **Scouts/Members**, **Leaders & Parents**, or **Payment Log** and save the CSV or tab-delimited file.
2. In TroopLedger, open **Imports → Scoutbook → Quick Export** and choose the file.
3. Review the detected export type, sample rows, valid-row count, and any issues. Change the export type if detection was incorrect.
4. Confirm the import. Roster exports add or update people and registration records; Payment Log exports add member-ledger entries.

To subscribe to the Scoutbook calendar:

1. Copy the Scoutbook calendar's secure subscription URL.
2. Open **Imports → Scoutbook → Calendar**, provide a useful name, paste the HTTPS URL, and choose **Add and Sync**.
3. Refresh a subscription from this screen whenever you want current events. Synced event title, dates, location, and notes are visibly read-only in TroopLedger; local financial records can still be associated with the event.

The subscription URL can grant access to troop schedule information. Treat it like a password and share it only with authorized adults. See `SCOUTBOOK_INTEGRATION.md` for mappings and current limitations.

## General spreadsheet import

To bring a transaction register from another workbook into TroopLedger, first export that sheet from Excel, Numbers, or another spreadsheet app as CSV or tab-delimited text. Then open **Imports → Spreadsheet**, choose the file and destination account, and review the detected field mapping. You can map date, amount or separate income/expense columns, direction, payee, category, memo, reference number, and cleared status. Defaults cover an omitted direction or category.

The preview does not write to the ledger. It shows importable totals and identifies invalid dates, amounts, mappings, and transactions that fall in a reconciled locked period. If exceptions remain, TroopLedger imports nothing unless you explicitly choose to skip the listed rows. Imported transactions retain the source filename and row number; the complete file fingerprint prevents an accidental second import. The outcome and reviewed exceptions are retained in general spreadsheet import history and the Audit Log, and that history is included in plaintext backups.

This flexible transaction importer is separate from the fingerprint-verified starting-workbook importer and does not change that import path.

## iCloud scope

This version uses SwiftData with the app’s private CloudKit database. It is intended to sync the treasurer’s own devices signed into the same Apple ID. It does not yet share the database with committee members using different Apple IDs. That requires CloudKit sharing and an explicit permissions design.

## Workbook import status

Version 0.3 includes a bundled, normalized snapshot of the supplied workbook and an explicit one-time importer. The original Excel file was not modified.

The snapshot contains 649 records: 1 account, 228 checking transactions, 26 cash receipts, 34 people, 97 annual registrations, 27 current member-ledger entries, 24 events, and 212 event financial lines. Its checking balance independently recalculates to **$836.38**, matching the workbook. Duplicate protection uses the workbook's SHA-256 fingerprint.

Cash Register rows and event worksheet lines remain separate supporting records; they do not post a second time to the bank account. Source sheet and row numbers are retained for audit tracing. See `IMPORT_REPORT.md` for details and limitations.

## Project generation and verification

The checked-in `.xcodeproj` is ready to open. The project definition is also kept in `project.yml`; after editing that file, regenerate with:

```sh
xcodegen generate
```

The project includes forty-six unit tests covering account and separated Undeposited Funds balances, duplicate-safe audited holding-account setup, batch-deposit allocation preservation, matched-transfer posting, duplicate and period-lock protection, reviewed fixed-dues and assessed-registration charge batches, immutable per-person allocations, exact batch-charge duplicate protection, transfer exclusion from financial reports, complete plaintext JSON/CSV/receipt/deposit/family/charge-batch/event-close-out backup coverage, reconciliation balances and period locks, adjusting-entry validation, persisted audit metadata, standard and register-derived category seeding, working/approved operating-budget records, budget-to-actual variance, monthly report boundaries, fingerprinted committee packages, complete annual audit packages, September-to-August reporting boundaries and cross-calendar-year aggregation, retained calendar-year reporting, member charges/payments/credits, recharter projections, family-statement calculations and PDF generation, person status and role filtering, ranks and positions, event-roster PDF generation, fee calculations, duplicate-safe event close-out and final member adjustments, reimbursement safeguards and reporting, workbook and spreadsheet imports, Scoutbook duplicate protection, and iCalendar event parsing/recurrence.
