import LocalAuthentication
import SwiftData
import SwiftUI

struct PreferencesView: View {
    var showsDismissButton = true

    var body: some View {
        TabView {
            TroopProfileSettingsView(showsDismissButton: showsDismissButton)
                .tabItem { Label("Troop Profile", systemImage: "flag") }
            DisbursementControlSettingsView(showsDismissButton: showsDismissButton)
                .tabItem { Label("Controls", systemImage: "checkmark.shield") }
            AppearanceSettingsView(showsDismissButton: showsDismissButton)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
#if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
#endif
    }
}

struct TroopProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.dismissWindow) private var dismissWindow
#endif
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TroopProfileRecord.modifiedAt, order: .reverse) private var storedProfiles: [TroopProfileRecord]
    var showsDismissButton = true

    @State private var troopName = ""
    @State private var troopNumber = ""
    @State private var council = ""
    @State private var district = ""
    @State private var charteredOrganization = ""
    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var stateOrProvince = ""
    @State private var postalCode = ""
    @State private var country = ""
    @State private var unitEmail = ""
    @State private var unitPhone = ""
    @State private var website = ""
    @State private var treasurerName = ""
    @State private var treasurerPreferredName = ""
    @State private var treasurerTitle = "Treasurer"
    @State private var treasurerEmail = ""
    @State private var treasurerPhone = ""
    @State private var committeeChairName = ""
    @State private var notes = ""
    @State private var loaded = false
    @State private var savedFingerprint = ""
    @State private var lastSavedAt: Date?
    @State private var showingCloseConfirmation = false
    @State private var errorMessage: String?
    @State private var showingSaveMilestone = false

    private var currentFingerprint: String {
        [
            troopName, troopNumber, council, district, charteredOrganization,
            addressLine1, addressLine2, city, stateOrProvince, postalCode, country,
            unitEmail, unitPhone, website, treasurerName, treasurerPreferredName,
            treasurerTitle, treasurerEmail, treasurerPhone, committeeChairName, notes,
        ].joined(separator: "\u{001F}")
    }

    private var hasUnsavedChanges: Bool { loaded && currentFingerprint != savedFingerprint }

    private var saveStatus: String {
        if hasUnsavedChanges { return "Unsaved changes" }
        if !storedProfiles.isEmpty || lastSavedAt != nil { return "Saved" }
        return "No profile saved yet"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Unit Identity") {
                    TextField("Troop name", text: $troopName, prompt: Text("Mayflower Troop"))
                    TextField("Troop number", text: $troopNumber, prompt: Text("51"))
                    TextField("Council", text: $council)
                    TextField("District", text: $district)
                    TextField("Chartered organization", text: $charteredOrganization)
                }

                Section("Mailing Address") {
                    TextField("Street address", text: $addressLine1)
                    TextField("Apartment, suite, or mail stop", text: $addressLine2)
                    TextField("City", text: $city)
                    TextField("State or province", text: $stateOrProvince)
                    TextField("Postal code", text: $postalCode)
                    TextField("Country", text: $country)
                }

                Section("Unit Contact") {
                    TextField("Unit email", text: $unitEmail)
                    TextField("Unit phone", text: $unitPhone)
                    TextField("Website", text: $website)
                }

                Section("Treasurer") {
                    TextField("Full name", text: $treasurerName)
                    TextField("Name used in greetings", text: $treasurerPreferredName, prompt: Text("Dom"))
                    TextField("Title", text: $treasurerTitle)
                    TextField("Email", text: $treasurerEmail)
                    TextField("Phone", text: $treasurerPhone)
                    Text("The preferred name is used for dashboard greetings such as “Good afternoon, Dom.”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Other Leadership") {
                    TextField("Committee chair", text: $committeeChairName)
                }

                Section("Internal Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    Text("Contact details and notes are stored with the app and included in full backups. Report headers use only the unit identity, address, and treasurer name.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Troop Profile")
            .toolbar {
#if os(iOS)
                if showsDismissButton {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: attemptClose) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasUnsavedChanges)
                }
#endif
            }
            .onAppear { load() }
        }
#if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Label(
                    saveStatus,
                    systemImage: hasUnsavedChanges ? "circle.fill" : "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(hasUnsavedChanges ? Color.orange : Color.secondary)

                Spacer()

                Button("Revert", action: revert)
                    .disabled(!hasUnsavedChanges)
                Button("Close", action: attemptClose)
                Button("Save") { save() }
                    .buttonStyle(.fieldbookProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasUnsavedChanges)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
#endif
        .interactiveDismissDisabled(hasUnsavedChanges)
#if os(macOS)
        .windowDismissBehavior(hasUnsavedChanges ? .disabled : .enabled)
#endif
        .confirmationDialog("Save changes to the troop profile?", isPresented: $showingCloseConfirmation) {
            Button("Save and Close") { save(closeAfterSaving: true) }
            Button("Discard Changes", role: .destructive) {
                revert()
                closePreferences()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closing without saving will discard the changes made in this window.")
        }
        .alert("Troop Profile", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: {
            Text(errorMessage ?? "")
        }
        .scoutMilestoneOverlay(
            isPresented: $showingSaveMilestone,
            title: "Fieldbook Saved",
            subtitle: "Troop profile changes are secure.",
            systemImage: "checkmark.seal.fill"
        )
    }

    private func load(force: Bool = false) {
        guard !loaded || force else { return }
        loaded = true
        let profile = storedProfiles.first
        troopName = profile?.troopName ?? ""
        troopNumber = profile?.troopNumber ?? ""
        council = profile?.council ?? ""
        district = profile?.district ?? ""
        charteredOrganization = profile?.charteredOrganization ?? ""
        addressLine1 = profile?.addressLine1 ?? ""
        addressLine2 = profile?.addressLine2 ?? ""
        city = profile?.city ?? ""
        stateOrProvince = profile?.stateOrProvince ?? ""
        postalCode = profile?.postalCode ?? ""
        country = profile?.country ?? ""
        unitEmail = profile?.unitEmail ?? ""
        unitPhone = profile?.unitPhone ?? ""
        website = profile?.website ?? ""
        treasurerName = profile?.treasurerName ?? ""
        treasurerPreferredName = profile?.treasurerPreferredName ?? ""
        treasurerTitle = profile?.treasurerTitle ?? "Treasurer"
        treasurerEmail = profile?.treasurerEmail ?? ""
        treasurerPhone = profile?.treasurerPhone ?? ""
        committeeChairName = profile?.committeeChairName ?? ""
        notes = profile?.notes ?? ""
        savedFingerprint = currentFingerprint
    }

    private func save(closeAfterSaving: Bool = false) {
        do {
            let profile = storedProfiles.first ?? TroopProfileRecord()
            let isNew = storedProfiles.isEmpty
            profile.troopName = clean(troopName)
            profile.troopNumber = clean(troopNumber)
            profile.council = clean(council)
            profile.district = clean(district)
            profile.charteredOrganization = clean(charteredOrganization)
            profile.addressLine1 = clean(addressLine1)
            profile.addressLine2 = clean(addressLine2)
            profile.city = clean(city)
            profile.stateOrProvince = clean(stateOrProvince)
            profile.postalCode = clean(postalCode)
            profile.country = clean(country)
            profile.unitEmail = clean(unitEmail)
            profile.unitPhone = clean(unitPhone)
            profile.website = clean(website)
            profile.treasurerName = clean(treasurerName)
            profile.treasurerPreferredName = clean(treasurerPreferredName)
            profile.treasurerTitle = clean(treasurerTitle)
            profile.treasurerEmail = clean(treasurerEmail)
            profile.treasurerPhone = clean(treasurerPhone)
            profile.committeeChairName = clean(committeeChairName)
            profile.notes = clean(notes)
            profile.modifiedAt = Date()
            if isNew { modelContext.insert(profile) }

            AuditLogger.record(
                isNew ? .create : .edit,
                recordType: "Troop Profile",
                recordID: profile.id,
                summary: "Updated \(profile.formalName)",
                details: AuditLogger.details([
                    ("Council", profile.council),
                    ("District", profile.district),
                    ("Treasurer", profile.treasurerName),
                ]),
                in: modelContext
            )
            try modelContext.save()
            savedFingerprint = currentFingerprint
            lastSavedAt = Date()
            if closeAfterSaving {
                closePreferences()
            } else {
                showingSaveMilestone = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revert() {
        load(force: true)
    }

    private func attemptClose() {
        if hasUnsavedChanges {
            showingCloseConfirmation = true
        } else {
            closePreferences()
        }
    }

    private func closePreferences() {
#if os(macOS)
        dismissWindow(id: "preferences")
#else
        dismiss()
#endif
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DisbursementControlSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DisbursementControlSettings.modifiedAt, order: .reverse) private var storedSettings: [DisbursementControlSettings]
    var showsDismissButton = true
    @State private var isEnabled = true
    @State private var expectApprover = true
    @State private var expectedSignerCount = 2
    @State private var warnSamePerson = true
    @State private var warnSameHousehold = true
    @State private var warnMissingHousehold = true
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var backupDocument: PlaintextBackupDocument?
    @State private var backupFilename = PlaintextBackupService.defaultFilename()
    @State private var backupRecordCount = 0
    @State private var backupFingerprint = ""
    @State private var showingBackupExporter = false
    @State private var backupMessage: String?
    @State private var backupError: String?
    @State private var showingFirstResetConfirmation = false
    @State private var showingFinalResetConfirmation = false
    @State private var resetConfirmationText = ""
    @State private var resetMessage: String?
    @State private var resetError: String?
    @State private var isResetting = false
    @State private var backupAcknowledged = false
    @AppStorage(AppLockPolicy.storageKey) private var requiresDeviceAuthentication = false

    private var deviceLockBinding: Binding<Bool> {
        Binding(
            get: { requiresDeviceAuthentication },
            set: { enabled in
                guard enabled else { requiresDeviceAuthentication = false; return }
                var availabilityError: NSError?
                if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) {
                    requiresDeviceAuthentication = true
                } else {
                    errorMessage = availabilityError?.localizedDescription ?? "Set a device passcode, Touch ID, or Face ID before turning on the lock."
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reimbursements") {
                    Toggle("Enable dual-control tracking", isOn: $isEnabled)
                    Text(isEnabled
                        ? "TroopLedger will offer approver and signer evidence and show the configured advisory warnings."
                        : "Existing evidence remains stored and backed up, but dual-control fields and warnings are hidden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Expected Evidence") {
                    Toggle("Expect an approver", isOn: $expectApprover)
                    Picker("Expected check signers", selection: $expectedSignerCount) {
                        Text("None").tag(0)
                        Text("One").tag(1)
                        Text("Two").tag(2)
                    }
                }
                .disabled(!isEnabled)
                Section("Advisory Warnings") {
                    Toggle("Same person in multiple roles", isOn: $warnSamePerson)
                    Toggle("Same household label", isOn: $warnSameHousehold)
                    Toggle("Missing household label", isOn: $warnMissingHousehold)
                }
                .disabled(!isEnabled)
                Section {
                    Text("These settings control warnings only. TroopLedger records the evidence you enter and does not determine whether a disbursement is legally or organizationally compliant.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Device Access") {
                    Toggle("Require Face ID, Touch ID, or passcode", isOn: deviceLockBinding)
                    Text("When on, TroopLedger locks whenever it moves to the background on this device and asks for device authentication before showing the books again. Other devices are not affected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Start Over") {
                    Label {
                        Text("Deleting all records is permanent. It removes the troop profile, accounts, transactions, people, events, receipts, reports, import history, and audit log from this database and from devices synced through iCloud.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)

                    Text("Before starting over, export a full plaintext backup and store it securely. TroopLedger 1.0 does not restore this backup inside the app, but the package preserves the records for safekeeping and treasurer handoff.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Export Backup Before Starting Over", systemImage: "externaldrive.badge.plus") {
                        prepareBackup()
                    }
                    .disabled(isResetting)

                    Toggle("I have a current backup of these records", isOn: $backupAcknowledged)
                    Button("Delete All Records and Start Over", systemImage: "trash", role: .destructive) {
                        showingFirstResetConfirmation = true
                    }
                    .disabled(isResetting || !backupAcknowledged)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Disbursement Controls")
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear(perform: load)
        }
        .frame(minWidth: 480, minHeight: 460)
        .fileExporter(
            isPresented: $showingBackupExporter,
            document: backupDocument,
            contentType: .troopLedgerBackup,
            defaultFilename: backupFilename
        ) { result in
            completeBackupExport(result)
        }
        .confirmationDialog(
            "Delete all TroopLedger records?",
            isPresented: $showingFirstResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue to Final Confirmation", role: .destructive) {
                resetConfirmationText = ""
                showingFinalResetConfirmation = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone and will also delete the records from devices synced through iCloud. Export a backup first if you may need these records later.")
        }
        .alert("Final Confirmation", isPresented: $showingFinalResetConfirmation) {
            TextField("Type DELETE", text: $resetConfirmationText)
            Button("Delete All Records", role: .destructive) {
                deleteAllRecords()
            }
            .disabled(resetConfirmationText != "DELETE")
            Button("Cancel", role: .cancel) {
                resetConfirmationText = ""
            }
        } message: {
            Text("Type DELETE in capital letters to confirm that you want to permanently erase the complete TroopLedger database and start over.")
        }
        .alert("Plaintext Backup", isPresented: Binding(
            get: { backupMessage != nil || backupError != nil },
            set: { if !$0 { backupMessage = nil; backupError = nil } }
        )) {
            Button("OK") { backupMessage = nil; backupError = nil }
        } message: {
            Text(backupError ?? backupMessage ?? "")
        }
        .alert("Start Over", isPresented: Binding(
            get: { resetMessage != nil || resetError != nil },
            set: { if !$0 { resetMessage = nil; resetError = nil } }
        )) {
            Button("OK") { resetMessage = nil; resetError = nil }
        } message: {
            Text(resetError ?? resetMessage ?? "")
        }
        .alert("Disbursement Controls", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let policy = DisbursementControlPolicy(settings: storedSettings.first)
        isEnabled = policy.isEnabled
        expectApprover = policy.expectApprover
        expectedSignerCount = policy.expectedSignerCount
        warnSamePerson = policy.warnSamePerson
        warnSameHousehold = policy.warnSameHousehold
        warnMissingHousehold = policy.warnMissingHousehold
    }

    private func save() {
        do {
            let settings = storedSettings.first ?? DisbursementControlSettings()
            let isNew = storedSettings.isEmpty
            settings.isEnabled = isEnabled
            settings.expectApprover = expectApprover
            settings.expectedSignerCount = min(max(expectedSignerCount, 0), 2)
            settings.warnSamePerson = warnSamePerson
            settings.warnSameHousehold = warnSameHousehold
            settings.warnMissingHousehold = warnMissingHousehold
            settings.modifiedAt = Date()
            if isNew { modelContext.insert(settings) }
            AuditLogger.record(
                isNew ? .create : .edit,
                recordType: "Disbursement Control Settings",
                recordID: settings.id,
                summary: "Updated disbursement warning settings",
                details: AuditLogger.details([
                    ("Enabled", String(isEnabled)),
                    ("Expect approver", String(expectApprover)),
                    ("Expected signers", String(settings.expectedSignerCount)),
                    ("Warn same person", String(warnSamePerson)),
                    ("Warn same household", String(warnSameHousehold)),
                    ("Warn missing household", String(warnMissingHousehold)),
                ]),
                in: modelContext
            )
            try modelContext.save()
            if showsDismissButton { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareBackup() {
        do {
            try modelContext.save()
            let exportedAt = Date()
            let archive = try PlaintextBackupService.makeArchive(from: modelContext, exportedAt: exportedAt)
            backupDocument = PlaintextBackupDocument(files: archive.files)
            backupFilename = PlaintextBackupService.defaultFilename(at: exportedAt)
            backupRecordCount = archive.recordCounts.values.reduce(0, +)
            backupFingerprint = CommitteeReportPackageService.fingerprint(of: archive.files)
            showingBackupExporter = true
        } catch {
            backupError = "The backup could not be prepared: \(error.localizedDescription)"
        }
    }

    private func completeBackupExport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AuditLogger.record(
                .export,
                recordType: "Plaintext Backup",
                recordID: nil,
                summary: "Exported full plaintext backup before starting over",
                details: AuditLogger.details([
                    ("File", url.lastPathComponent),
                    ("Records", String(backupRecordCount)),
                    ("Format version", String(PlaintextBackupService.formatVersion)),
                    ("Manifest SHA-256", backupFingerprint),
                ]),
                in: modelContext
            )
            backupAcknowledged = true
            do {
                try modelContext.save()
                backupMessage = "Backup exported successfully with \(backupRecordCount) records. Keep it in a secure location."
            } catch {
                backupError = "The backup was exported, but its audit entry could not be saved: \(error.localizedDescription)"
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(error is CancellationError), nsError.code != NSUserCancelledError else { return }
            backupError = "The backup could not be exported: \(error.localizedDescription)"
        }
    }

    private func deleteAllRecords() {
        isResetting = true
        defer {
            isResetting = false
            resetConfirmationText = ""
        }

        do {
            let result = try DataResetService.deleteAllRecords(from: modelContext)
            applyDefaultSettings()
            resetMessage = result.deletedRecordCount == 1
                ? "1 record was deleted. TroopLedger is ready for a new setup."
                : "\(result.deletedRecordCount) records were deleted. TroopLedger is ready for a new setup."
        } catch {
            resetError = "TroopLedger could not delete the records. No partial reset was saved. \(error.localizedDescription)"
        }
    }

    private func applyDefaultSettings() {
        isEnabled = true
        expectApprover = true
        expectedSignerCount = 2
        warnSamePerson = true
        warnSameHousehold = true
        warnMissingHousehold = true
        loaded = true
    }
}

struct DisbursementControlEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    let request: ReimbursementRequest
    @State private var approverPersonID: UUID?
    @State private var approverName: String
    @State private var approverHousehold: String
    @State private var signerOnePersonID: UUID?
    @State private var signerOneName: String
    @State private var signerOneHousehold: String
    @State private var signerTwoPersonID: UUID?
    @State private var signerTwoName: String
    @State private var signerTwoHousehold: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(request: ReimbursementRequest) {
        self.request = request
        _approverPersonID = State(initialValue: request.approverPersonID)
        _approverName = State(initialValue: request.approverNameSnapshot)
        _approverHousehold = State(initialValue: request.approverHouseholdSnapshot)
        _signerOnePersonID = State(initialValue: request.signerOnePersonID)
        _signerOneName = State(initialValue: request.signerOneNameSnapshot)
        _signerOneHousehold = State(initialValue: request.signerOneHouseholdSnapshot)
        _signerTwoPersonID = State(initialValue: request.signerTwoPersonID)
        _signerTwoName = State(initialValue: request.signerTwoNameSnapshot)
        _signerTwoHousehold = State(initialValue: request.signerTwoHouseholdSnapshot)
        _notes = State(initialValue: request.disbursementControlNotes)
    }

    /// Departed leaders stay off the evidence pickers; an already-recorded identity remains selectable.
    private var adults: [PersonRecord] {
        let recorded: Set<UUID?> = [approverPersonID, signerOnePersonID, signerTwoPersonID]
        return people.filter { $0.role != .scout && $0.id != request.requesterPersonID && ($0.isActive || recorded.contains($0.id)) }
    }

    var body: some View {
        NavigationStack {
            Form {
                ControlIdentityFields(
                    title: "Approver",
                    personID: $approverPersonID,
                    name: $approverName,
                    household: $approverHousehold,
                    people: adults
                )
                ControlIdentityFields(
                    title: "Check Signer 1",
                    personID: $signerOnePersonID,
                    name: $signerOneName,
                    household: $signerOneHousehold,
                    people: adults
                )
                ControlIdentityFields(
                    title: "Check Signer 2",
                    personID: $signerTwoPersonID,
                    name: $signerTwoName,
                    household: $signerTwoHousehold,
                    people: adults
                )
                Section("Notes") {
                    TextField("Control evidence notes", text: $notes, axis: .vertical)
                }
                Section {
                    Text("Names and household labels are saved as historical snapshots. Household labels are administrative labels you enter—not contact addresses. Warnings are advisory and never block payment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Disbursement Evidence")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .frame(minWidth: 500, minHeight: 650)
        .alert("Disbursement Evidence", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            try ReimbursementService.saveDisbursementControls(
                for: request,
                approver: .init(personID: approverPersonID, name: approverName, household: approverHousehold),
                signerOne: .init(personID: signerOnePersonID, name: signerOneName, household: signerOneHousehold),
                signerTwo: .init(personID: signerTwoPersonID, name: signerTwoName, household: signerTwoHousehold),
                notes: notes,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DisbursementControlSummaryView: View {
    @Query private var people: [PersonRecord]
    @Query private var families: [FamilyRecord]
    let request: ReimbursementRequest
    let policy: DisbursementControlPolicy
    var showEvidence = true

    private var requesterIdentity: DisbursementControlIdentity? {
        guard let requesterID = request.requesterPersonID else { return nil }
        let requester = people.first { $0.id == requesterID }
        let household = requester?.familyID.flatMap { familyID in families.first { $0.id == familyID }?.name } ?? ""
        return DisbursementControlIdentity(personID: requesterID, name: requester?.displayName ?? "", household: household)
    }

    private var assessment: DisbursementControlAssessment {
        ReimbursementService.assessment(for: request, policy: policy, requester: requesterIdentity)
    }

    var body: some View {
        if showEvidence {
            identityRow("Approver", request.controlIdentity(for: .approver))
            identityRow("Signer 1", request.controlIdentity(for: .signerOne))
            identityRow("Signer 2", request.controlIdentity(for: .signerTwo))
            if let date = request.disbursementControlRecordedAt {
                LabeledContent("Evidence recorded", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if !request.disbursementControlNotes.isEmpty {
                LabeledContent("Control notes", value: request.disbursementControlNotes)
            }
        }
        if assessment.warnings.isEmpty {
            Label("No warnings under the current settings.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else {
            ForEach(Array(assessment.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        Text("Warnings are advisory; verify current troop and governing requirements separately.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func identityRow(_ title: String, _ identity: DisbursementControlIdentity) -> some View {
        if identity.isRecorded {
            LabeledContent(title, value: identity.household.isEmpty ? identity.name : "\(identity.name) • \(identity.household)")
        } else {
            LabeledContent(title, value: "Not recorded")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ControlIdentityFields: View {
    let title: String
    @Binding var personID: UUID?
    @Binding var name: String
    @Binding var household: String
    let people: [PersonRecord]

    var body: some View {
        Section(title) {
            Picker("Adult roster record", selection: $personID) {
                Text("No linked record").tag(nil as UUID?)
                ForEach(people) { Text($0.displayName).tag($0.id as UUID?) }
            }
            TextField("Name snapshot", text: $name)
            TextField("Household label (optional)", text: $household)
        }
        .onChange(of: personID) { _, newID in
            if let person = people.first(where: { $0.id == newID }) {
                name = person.displayName
            }
        }
    }
}
