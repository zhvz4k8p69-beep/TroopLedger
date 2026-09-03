# TroopLedger design and workbook findings

## What the workbook currently does

The attached workbook contains 45 sheets and 44 detected table regions. It has evolved from a pack-oriented template into a troop ledger, so several labels and named formulas still use `Pack`, `Cubs`, or `Den` even though current data is for Troop 13.

The major patterns are:

- **Checking Account:** a 237-row register with check/reference number, date, description, withdrawal, deposit, cleared mark, running balance, and notes.
- **Cash Register:** a separate list of cash, checks, and other receipts before or outside deposit entry.
- **Scout registers:** yearly sheets use two rows per Scout. One row represents amounts owed or charged; the paired row represents payments/credits. Each new event becomes another column.
- **Adult registers:** use the same paired-row pattern, with annual registration dues and event charges.
- **Events:** about two dozen copied event sheets place expenses and income side-by-side and calculate an event net.
- **Budgets:** approved and working operating budgets, patrol budget tracking, and actual-versus-budget areas.
- **Committee report:** manually assembled account, deposit, member-balance, and monthly cash-flow figures.

The inspection also found seven visible formula errors: six divide-by-zero cells in Patrol Budget Tracking and one empty-range average in Troop Budget Tracking. Several report values are typed directly into formulas, and some yearly sheets retain stale date labels. These are good examples of why the app should calculate from normalized records rather than duplicated formulas and copied tabs.

## Design principles

1. **One transaction, one record.** New years and new events do not create new columns or tables.
2. **Bank cash and member balances are different ledgers.** A Scout can owe money without a bank transaction yet, and a bank deposit can combine several families’ payments.
3. **Reports are derived.** Balances, event actuals, and annual totals are calculated from source records and cannot be overwritten independently.
4. **Money uses integer cents.** This eliminates binary floating-point drift.
5. **Reconciliation is explicit.** Clearing a transaction and completing a bank statement are recorded actions.
6. **The original workbook remains read-only until migration rules are approved.**
7. **Collect only necessary youth data.** The initial model intentionally omits medical records and other high-sensitivity information.

## Data model

| Record | Purpose |
|---|---|
| Account | Checking, savings, cash on hand, or another financial account with an opening balance |
| Transaction | A deposit or expense with date, category, payee, reference, clearing state, and optional person/event links |
| Person | Scout, leader, parent/guardian, or other participant, with current rank and multiple current troop positions |
| Registration | Annual registration status, role, dates, and assessed dues for one person |
| Member ledger entry | Charge, payment, credit, or adjustment affecting what a person owes or is owed |
| Event | Dates, location, coordinator, status, capacity, budget, deadline, and notes |
| Event financial entry | Actual or projected detail preserved from an event worksheet without posting it again to a bank account |
| Event participant | Registration/attendance status, event fee, amount paid, and transportation notes |
| Cash receipt | Person, purpose, amount, and payment type preserved from the Cash Register without duplicating a bank deposit |
| Reconciliation | Bank statement date, ending balance, cleared balance, completion date, and notes |
| Import record | Source fingerprint, import date, and counts used for duplicate protection and audit history |
| Scoutbook import record | Quick Export fingerprint, selected export type, outcome counts, and exception notes |
| External calendar subscription | A named secure iCalendar URL, last sync state, and refresh error |
| Audit log entry | Append-only activity metadata, record reference, summary, device, operating system, and available user identity |

Records use UUID links rather than required object relationships. This keeps the CloudKit schema tolerant of sync ordering while still allowing the app to connect related data.

## App structure

- **Dashboard:** headline balances, outstanding member amounts, uncleared count, accounts, recent transactions, and upcoming events.
- **Transactions:** searchable bank register plus a separate imported Cash Receipts view.
- **People:** current Scouts BSA rank, multiple youth/adult troop positions, custom local positions, registration history, and an individual member ledger.
- **Events:** month calendar and list views, timed or all-day schedules, Troop/District/Council/National classification, venue/address/instructions with Apple Maps integration, editable multiline notes, planning information, budget versus actual, participants, imported worksheet detail, fee balances, and linked transactions.
- **Reconcile:** statement balance, cleared-transaction selection, live difference, and reconciliation history.
- **Budget:** reusable income/expense category definitions, school-year working budgets, and dated approved revisions.
- **Reports:** September-through-August school-year income/expense by category, retained calendar-year reporting, budget-to-actual variance, current balance report, and full plaintext backup export.
- **Audit Log:** searchable, filterable, read-only activity history with record links, timestamps, and available device/user identity.
- **Accounts:** opening balance and account setup.
- **Imports:** supplied-workbook migration plus Scoutbook Plus Quick Export preview/import and read-only calendar subscriptions.

The split-view navigation adapts across iPhone, iPad, and Mac while keeping the same information architecture.

## iCloud architecture

The app uses SwiftData with a CloudKit-enabled `ModelContainer` and the `iCloud.com.bettnet.TroopLedger` container entitlement.

This is appropriate for syncing the treasurer’s own iPhone, iPad, and Mac under one Apple ID. It is not sufficient for a troop committee whose members use different Apple IDs. Multi-user access should be a separate phase using CloudKit sharing, with roles such as:

- Treasurer: full edit and reconciliation access
- Committee chair: read reports and approve expenses
- Event coordinator: edit only assigned events and participants
- Auditor: read-only records and reconciliation history

Conflict handling and an audit trail should be designed before enabling shared writes.

## Implemented workbook migration

Version 0.3 contains a normalized snapshot of the exact supplied workbook and a user-initiated importer. The import retains stable identifiers and source-sheet/source-row references, checks its own verification data before inserting anything, and records the workbook SHA-256 fingerprint to prevent an accidental second import.

The checking register is the authoritative source for the account balance. Cash Register rows are imported as supporting receipt records, and event worksheet income/expense lines are imported as event financial entries. Neither set posts again to checking, avoiding duplicate deposits and expenses. The complete imported register independently recalculates to the workbook ending balance of $836.38.

The current paired Scout/adult rows are converted to member-ledger entries that reproduce each current balance. Annual sheets are retained as registration-history records. Imported event sheets become events with actual/projected line detail.

Most event sheets provide only month and year. Those events start on the first day of that month, carry an Approximate marker, and must be edited when exact dates are known. See `IMPORT_REPORT.md` for the record counts and remaining audit steps.

## Scoutbook integration architecture

TroopLedger stays on Scoutbook's supported user-facing integration surface: downloaded Quick Export files and the iCalendar subscription URL. It never asks for or persists a Scoutbook password and does not depend on private web endpoints.

CSV and TSV data is parsed locally. Before writing, the app detects the likely export type, presents samples and validation counts, and requires confirmation. Roster rows are matched by Scouting Member ID when available and then by normalized name. Payment rows have stable content fingerprints, so a later overlapping export does not add the same ledger row again. Each whole-file fingerprint and outcome is retained for audit history.

Calendar refresh downloads no more than 5 MB over HTTPS, parses iCalendar events, and upserts them by subscription and event UID. Synced title, dates, location, and notes remain read-only so a later refresh cannot silently overwrite locally edited source fields. Their financial links and supporting local records remain TroopLedger data. Current recurrence expansion supports basic daily, weekly, monthly, and yearly frequency, interval, count, and until rules for a two-year horizon; advanced rules such as BYDAY and exception dates require a later standards-complete parser.

## Release plan

The release boundary is based on operational risk rather than feature count. Version 1.0 makes TroopLedger a dependable, auditable system of record for one treasurer managing one troop and provides portable reports for everyone else. Version 2.0 adds multiple separately managed troops, specialized program accounting, privacy-sensitive workflows, multi-user collaboration, and external financial integrations after the core ledger and audit model are stable.

### Version 1.0 — Treasurer system of record

#### Ledger controls and portability

- **Period locking and adjusting entries (implemented in 0.5):** completing a reconciliation locks that account through the statement date so historical transactions cannot be edited, deleted, or inserted silently. Corrections after a lock are separately dated adjustment entries with a required explanation and a link to the affected transaction.
- **Append-only change log (implemented in 0.6):** record creation, editing, deletion, import, calendar sync, reconciliation, locking, and adjustment activity with timestamps and the available device/user identity. Entries are read-only in the app and begin with version 0.6; they will be included in later audit exports.
- **Full plaintext backup (implemented in 0.7, attachments added in 0.11):** export a self-contained `.troopledgerbackup` directory package containing a complete JSON snapshot, normalized CSV for every persisted table, a plain-text guide, and an attachment manifest. Records are sorted by UUID, relationships remain UUID references, dates use UTC ISO 8601, money remains integer cents, and CSV text uses RFC-style quoting. Reimbursement receipts are exported beneath `attachments/` with their original filename, media type, byte count, and SHA-256 checksum in the manifest. Successful exports are added to the audit log. This is the independent backup and treasurer-handoff format; version 1.0 will not add a second synchronization backend.
- **Reporting year (implemented in 0.8):** default to the troop's fixed 12-month school year running September 1 through August 31, with explicit year labels and boundary dates. Preserve January-through-December calendar-year reporting as an alternate view and remember the selected basis per device. Do not expose an arbitrary fiscal-start-month setting; the troop selected September as the reporting-year boundary.
- **Standard categories and operating budgets (implemented in 0.9):** seed reusable income and expense definitions from a standard troop catalog plus categories already used in the register. Support one editable working budget per September-through-August school year and preserve each approval as a dated, read-only revision. Reports use the newest approved revision, fall back to the working budget, include unbudgeted actual activity, and show favorable variance as income above plan or expenses below plan. Category archival and renaming never rewrite historical transactions or approved budget snapshots.
- **General-purpose spreadsheet import (implemented in 0.10):** import transaction-register CSV or TSV files exported from arbitrary spreadsheets into a selected account. Automatically detect common columns, allow explicit field mapping and defaults, and show a no-write preview with totals and row-level validation. Rows in locked periods remain rejected; exception rows require explicit review and opt-in skipping. Preserve source filenames and row numbers, prevent exact-file duplicates by fingerprint, retain audited import history, and keep the verified starting-workbook importer separate and unchanged.

#### Money going out

- **Reimbursement requests (implemented in 0.11):** record the requester, purchase date, business purpose, amount, expense category, optional event, and notes. Attach and preview fingerprinted image or PDF receipts; iPhone and iPad can scan multi-page documents with the system document camera. Approval or decline records the reviewer and freezes request details and evidence. Payment can link one existing exact-amount expense or create one through the reconciled-period posting validator, preventing duplicate ledger entries. Every stage is audited, and receipt binaries and checksums are included in plaintext backup packages.
- **Dual-control disbursement metadata (implemented in 0.12, master switch added in 0.12.1):** optionally record an approver and up to two check signers using adult roster links plus immutable name and user-entered household-label snapshots. A master preference hides the entire workflow and its warnings without deleting historical evidence. Configurable expectations and same-person, same-household, and missing-household checks produce advisory warnings without blocking payment. Preferences are available from the standard Mac Settings command and keyboard shortcut or a gear button on iPhone and iPad. Evidence and settings are audited and included in plaintext backups. TroopLedger does not claim that a disbursement is legally or organizationally compliant.
- **Approval reporting (implemented in 0.13):** derive Receipt, Approval, Signer Controls, and Payment Link exceptions from every reimbursement using the current dual-control preference. Submitted, approved, paid, and declined requests have explicit workflow rules; linked expenses are checked for existence, direction, and exact amount. The interactive report links back to each request, and its audited CSV export includes every request, evidence snapshots, exception details, related audit-entry counts, and the latest audit date.

#### Money coming in and member communication

- **Undeposited Funds account (implemented in 0.14):** provide one duplicate-safe, audited holding account for cash and checks received but not yet included in a bank deposit. It is a distinct account kind rather than a naming convention, remains separate from Cash on Hand and bank balances in the dashboard and balance reports, and still contributes to total troop cash. Creating a batch bank deposit remains the next separate workflow.
- **Batch deposit builder (implemented in 0.15):** select unbatched Undeposited Funds income transactions and imported Cash Receipt rows, then post one bank deposit with immutable source, payer/person, event, purpose, payment-type, date, and amount allocations. Imported receipt rows become traceable holding-account income; matched transfer entries move the exact total into the selected bank account and are excluded from income, expense, and budget-variance reports. Duplicate sources, negative holding balances, and locked source or destination periods are rejected. Posted sources and transfers are read-only, fully audited, and preserved in plaintext backups.
- **Family statements (implemented in 0.16):** group existing people into one family without duplicating contacts or member-ledger balances, then derive a combined period statement with beginning balance, charges, payments, credits, signed adjustments, running and current balances, and future-dated charges. Export a letter-size, multi-page PDF through the system export sheet on every platform, omit unnecessary contact and Scouting identifiers, audit successful exports, and include family relationships in the plaintext backup. Automated email delivery remains a later feature.
- **Recurring dues and registration charges (implemented in 0.17):** create a no-write per-person preview before posting predictable charges. Fixed recurring-dues batches use one reviewed amount; registration batches use each selected person’s positive assessed dues from the preferred current registration record for an explicit program year. Posting creates ordinary member-ledger charges plus immutable name, amount, registration, and generated-entry allocations; it creates no bank income. Exact same-person/date/category/amount batch duplicates are rejected, posted history is read-only and audited, and all relationships are included in plaintext backup format 9.
- **Recharter cash forecast (implemented in 1.0):** project per-person registration, unit charter, and other known costs against current troop cash and explicitly entered expected collections. The active-person count and matching assessed-dues reference remain visible, and neither silently replaces the treasurer's planning assumptions.

#### Committee reporting and turnover

- **One-tap monthly treasurer report (implemented in 1.0):** generate a dated PDF containing opening and ending balances, activity by category, school-year budget variance through the selected month, outstanding member balances, Undeposited Funds, and reconciliation status.
- **Read-only committee snapshot (implemented in 1.0):** export a dated `.troopledgercommittee` package with the rendered PDF, summary/register/budget CSV files, and a SHA-256 manifest for committee review before shared database access.
- **Annual audit and treasurer-turnover package (implemented in 1.0):** generate a `.troopledgeraudit` package containing a period-focused PDF, register, budget-to-actual and approval-exception exports, plus the complete plaintext backup with reconciliations, member ledgers, event close-outs, attachments, change log, and a SHA-256 manifest.
- **Committee-ready CSV and PDF exports (implemented in 1.0):** support normal reporting and archival without requiring recipients to run TroopLedger.

#### Event financial completion

- **Pre-event fee calculator (implemented in 1.0):** calculate exact break-even and whole-dollar suggested participant fees from fixed costs, per-person costs, expected attendance, and an explicitly entered contingency or margin.
- **Event close-out workflow (implemented in 1.0):** freeze an immutable roster allocation, calculate actual per-participant cost, identify unpaid and refund-due balances, post or preserve proposed final member-ledger adjustments, record final variance, mark the event completed, and reject a second close-out.
- **Event registration references and fee schedules (implemented in 1.0):** retain council or venue confirmation numbers, store multiple named event-specific fees, and snapshot the selected schedule name and amount on each participant.

### Version 1.0 release gates

Version 1.0 meets its planned feature gates: the app reproduces balances from source records, prevents silent changes to reconciled history, traces imported and edited financial records, exports user-owned data independently of iCloud, and produces monthly, committee, and annual audit packages. Reimbursement and event close-out posting paths reject duplicate bank or member-ledger results.

### Version 2.0 — Programs, privacy, and collaboration

#### Multiple troops and separate books

- **Troop portfolio and switcher:** let one app installation manage more than one troop. A persistent troop switcher identifies the active troop by name and number before showing its dashboard, and the active troop remains unmistakable in navigation, reports, exports, and destructive confirmations.
- **Hard data isolation:** treat every troop as an independent set of books, not as a filter applied to one combined ledger. Each troop owns its profile, accounts, transactions, reconciliations and locks, categories, budgets, people and families, member ledgers, events, reimbursements and attachments, imports, settings, and audit history. Cross-troop totals are not shown by default.
- **Independent storage and sharing boundary:** prefer a separate persistent store and CloudKit zone/share for each troop instead of relying only on an optional `troopID` filter on every record. Opening a troop selects its store; ordinary queries cannot accidentally return another troop's records. CloudKit roles and participants are assigned separately for each troop.
- **Per-troop lifecycle:** create, archive, back up, restore, hand off, or remove one troop without affecting another. Full plaintext backups identify the troop and contain exactly one troop's records. Copying reusable category or report templates may be supported, but balances, transactions, people, attachments, and audit history are never copied implicitly.
- **Version 1 migration:** the existing single-troop store becomes the first managed troop through an atomic, restartable migration that preserves UUIDs, attachments, reconciliation locks, audit entries, and CloudKit identity. A verified pre-migration backup and record-count comparison are required before promotion.

#### Fundraising and Scout allocations

- **Fundraiser module:** model each fundraiser with dates, approval/application tracking, gross receipts, cost of goods, other expenses, net proceeds, per-Scout sales, deadlines, and document attachments.
- **Scout credit allocation policy:** let the committee record an allocation percentage and restrictions for each fundraiser, calculate allocations, and report how credits were used. The app will display a policy disclaimer and preserve the decision trail; it will not issue legal or tax-compliance conclusions or hard-code a supposedly safe percentage.
- **Restricted-credit rules:** optionally limit credits to dues, events, equipment, or another committee-defined purpose and preserve their source through later use.

#### Privacy-sensitive assistance

- **Financial assistance, camperships, and dues waivers:** record assistance without exposing it in general committee or family reports.
- **Privacy classifications:** mark fields and attachments as treasurer-only, limited-finance-team, or generally reportable.
- **Restricted exports and change-log access:** generate reports appropriate to the viewer without leaking assistance details while still allowing an authorized audit.

#### Expanded event and troop operations

- **Mileage and driver reimbursement:** extend the reimbursement workflow with mileage, rate, route/purpose, driver, vehicle, and event links.
- **Transportation planning:** track driver assignments and available seats in addition to the existing participant transportation notes.
- **Patrol budgets and reimbursement requests:** allocate patrol funds and route patrol spending through the same approval, attachment, and adjustment controls as troop spending.
- **Equipment inventory and annual property assessment:** record item, owner/custodian, purchase date, cost, condition, location, insurance notes, attachments, and disposition, then produce a dated annual report for the chartered organization.
- **Recharter workflow and alerts:** expand the 1.0 cash forecast into a checklist with registration status, deadlines, exceptions, and expiration reminders.

#### Collaboration and integrations

- **Role-based CloudKit sharing:** design and test Treasurer, Committee Chair, Event Coordinator, and Auditor permissions, conflict handling, and shared-write auditing before enabling committee members to edit the live database.
- **Bank file import and matching:** import CSV, OFX, or QFX statements and propose matches without bypassing explicit reconciliation.
- **Optional read-only bank feed:** evaluate only after file import and matching are reliable, using a vetted provider and a separate security review.
- **Automated statements and reminders:** generate scheduled email or message reminders from approved templates without exposing restricted balances or assistance data.
- **Calendar improvements:** add background refresh plus standards-complete recurrence, exception-date, and deletion handling.

### Version 2.0 release gates

Version 2.0 is ready when privacy classifications are enforced across screens, exports, notifications, and shared access; fundraiser allocations remain traceable from receipt through permitted use; concurrent edits cannot bypass period locks, approvals, or the audit log; and automated isolation tests prove that searches, reports, exports, notifications, backups, and CloudKit shares for one troop cannot expose or modify another troop's records. Two troops with overlapping account names, reporting dates, people names, and event names must reconcile and export independently.

## Decisions recorded by this roadmap

1. A positive member balance continues to mean that the family owes the troop.
2. Cash on hand and Undeposited Funds are separate accounts; batch deposits connect individual receipts to the bank deposit.
3. Reconciled periods will be locked, and later corrections will use explicit adjusting entries.
4. Plaintext JSON/CSV export is the version 1.0 backup and handoff solution instead of a second sync service.
5. Committee members receive dated read-only snapshots in version 1.0; role-based shared editing is deferred to version 2.0.
6. Family statements are generated and shareable in version 1.0; automated delivery is deferred to version 2.0.
7. Scout-credit percentages and restrictions are committee policy recorded by the app, not compliance judgments made by the app.
8. Financial-assistance data is excluded from general reports and requires the version 2.0 privacy model.
9. Reimbursement evidence and dual-control metadata are recorded and reported, but policy rules must remain configurable and must be verified against current governing guidance before release.
10. The default reporting year is a 12-month school year beginning September 1 and ending August 31; calendar-year reports remain available.
11. Version 2.0 may manage multiple troops, but each troop remains a separate set of books with its own storage, backup, audit, and CloudKit-sharing boundary; the app does not create a combined ledger.

## Remaining product decisions

1. Which bank-statement date establishes the first locked reconciliation after the workbook import?
2. Which registration fields are needed beyond Scouting Member ID, unit role, status, dates, and assessed dues?
3. Who may unlock a period, and should an unlock require a reason plus a second approval?
4. How long should receipt and reimbursement attachments be retained after an audit or treasurer turnover?
5. Should an event close-out post member-ledger adjustments immediately or always present a final approval preview?
6. Which identity source should the change log use before multi-user CloudKit sharing exists?
