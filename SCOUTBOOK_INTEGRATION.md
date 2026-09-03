# Scoutbook Plus integration

TroopLedger 0.4 integrates with Scoutbook Plus through downloaded Quick Export files and a read-only iCalendar subscription. It does not use private Scoutbook APIs, automate login, or store a Scoutbook username or password.

## Quick Export import

Open **Imports → Scoutbook → Quick Export**, select a `.csv`, `.tsv`, or text export, and review the dry-run preview before confirming.

Supported export types:

- **Scouts / Members:** creates or updates people and annual registration records.
- **Leaders & Parents:** creates or updates adult people and annual registration records.
- **Payment Log:** creates member-ledger charges, payments, credits, or adjustments.

When a roster export provides recognizable `Rank` and `Position` columns, TroopLedger also updates the person's current Scouts BSA rank and matches standard youth/adult positions. Unrecognized local positions remain available for manual entry in the person's **Other or troop-specific position** field.

The parser accepts comma- or tab-delimited text, quoted commas, and multiline quoted values. Header matching tolerates common variants such as `BSA Member ID`, `Scouting Member ID`, `Member Name`, `Transaction Date`, and `Transaction Amount`. The preview reports invalid rows and shows up to 50 row-specific issues.

Roster matching prefers Scouting Member ID and otherwise uses a normalized first-and-last name. Payment rows are matched to people the same way. A payment without a matching person is retained under a review-needed placeholder instead of being discarded.

Two safeguards prevent duplicate records:

1. The SHA-256 fingerprint of every completed export import prevents the exact same file from being imported again.
2. Every payment row receives a stable source ID, so an overlapping later Payment Log export skips transactions already present.

Import history stores source filename, export type, time, source-row count, insert/update/skip counts, and issue notes.

### Sign convention

When the export includes a recognizable transaction type, TroopLedger maps payments, credits, charges, and adjustments directly. Otherwise, a negative amount is treated as a charge and a positive amount as a payment. Always verify the member-balance report after the first real Payment Log import.

## Calendar subscription

Open **Imports → Scoutbook → Calendar**, enter a local display name, paste the Scoutbook HTTPS calendar subscription URL, and choose **Add and Sync**.

The app:

- accepts HTTPS URLs only;
- limits downloaded feeds to 5 MB;
- imports title, start/end, all-day status, location, notes, and external modification date;
- keeps Scoutbook-sourced fields read-only and marks them with a link icon;
- upserts an existing occurrence rather than duplicating it on refresh;
- shows synchronized events alongside local events in the month calendar and event list;
- removes synchronized events when the subscription is explicitly deleted.

Sync is manual in version 0.4. A refresh updates events returned by the feed but does not remove an event merely because it disappeared from a later feed. This protects local financial links until deletion semantics and audit behavior are defined.

Basic recurring events support `DAILY`, `WEEKLY`, `MONTHLY`, and `YEARLY`, with `INTERVAL`, `COUNT`, and `UNTIL`, expanded to a maximum of 500 occurrences and a two-year horizon. Advanced iCalendar recurrence options such as `BYDAY`, `EXDATE`, or moved-instance reconciliation are not yet supported.

## Privacy and first-production-use checks

The calendar URL is a bearer secret: anyone who has it may be able to read troop schedule details. Keep it within the authorized troop leadership and do not paste it into support messages or source control.

No real Scoutbook export or troop calendar URL was provided while version 0.4 was built. The importer and calendar parser are covered by representative CSV/iCalendar fixtures, but the first production import should be treated as a validation run:

1. Import a current roster export and compare person/registration counts.
2. Import a short Payment Log date range and compare several family balances.
3. Add the calendar feed and compare timed, all-day, multi-day, and recurring events.
4. If Scoutbook uses an unrecognized header or recurrence rule, stop before relying on the result and provide a redacted sample for mapping.
