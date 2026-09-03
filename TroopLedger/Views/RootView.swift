import LocalAuthentication
import SwiftUI

/// Optional device lock: when enabled in Preferences, the window blurs and asks for Face ID, Touch ID, or the
/// device passcode after the app moves to the background, so a shared family iPad or an unattended Mac does
/// not leave the troop's finances and contact details open.
struct AppLockGate: ViewModifier {
    @AppStorage(AppLockPolicy.storageKey) private var requiresAuthentication = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLocked = false
    @State private var isAuthenticating = false
    @State private var failureMessage: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if isLocked { lockScreen }
            }
            .onAppear {
                if requiresAuthentication {
                    isLocked = true
                    authenticate()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    if AppLockPolicy.shouldLock(isEnabled: requiresAuthentication, movedToBackground: true, alreadyLocked: isLocked) {
                        isLocked = true
                    }
                case .active:
                    if isLocked { authenticate() }
                default:
                    break
                }
            }
    }

    private var lockScreen: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("TroopLedger is locked").font(.title2.bold())
                if let failureMessage {
                    Text(failureMessage).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Unlock") { authenticate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating)
            }
            .padding(32)
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        let context = LAContext()
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            isAuthenticating = false
            failureMessage = availabilityError?.localizedDescription ?? "Device authentication is not available."
            return
        }
        let locked = $isLocked
        let authenticating = $isAuthenticating
        let failure = $failureMessage
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock the troop's financial records") { success, error in
            Task { @MainActor in
                authenticating.wrappedValue = false
                if success {
                    locked.wrappedValue = false
                    failure.wrappedValue = nil
                } else {
                    failure.wrappedValue = error?.localizedDescription
                }
            }
        }
    }
}

extension View {
    func appLockGate() -> some View { modifier(AppLockGate()) }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case transactions = "Transactions"
    case deposits = "Deposits"
    case reimbursements = "Reimbursements"
    case people = "People"
    case chargeBatches = "Charge Batches"
    case events = "Events"
    case reconcile = "Reconcile"
    case budget = "Budget"
    case reports = "Reports"
    case auditLog = "Audit Log"
    case accounts = "Accounts"
    case importData = "Imports"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: "safari.fill"
        case .transactions: "book.pages"
        case .deposits: "tray.full"
        case .reimbursements: "doc.text.image"
        case .people: "person.3.fill"
        case .chargeBatches: "person.2.badge.plus"
        case .events: "tent.2.fill"
        case .reconcile: "checkmark.seal.fill"
        case .budget: "target"
        case .reports: "book.closed.fill"
        case .auditLog: "point.topleft.down.to.point.bottomright.curvepath"
        case .accounts: "lockbox.fill"
        case .importData: "map.fill"
        }
    }

    var navigationGroup: AppNavigationGroup {
        switch self {
        case .dashboard:
            .overview
        case .transactions, .deposits, .reimbursements:
            .money
        case .people, .chargeBatches, .events:
            .troop
        case .reconcile, .budget, .reports:
            .closeAndReport
        case .auditLog, .accounts, .importData:
            .system
        }
    }
}

enum AppNavigationGroup: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case money = "Money"
    case troop = "Troop"
    case closeAndReport = "Close & Report"
    case system = "System"

    var id: String { rawValue }
}

struct RootView: View {
    @State private var selection: AppSection? = .dashboard
#if os(macOS)
    @AppStorage("navigationSidebarIsCompact") private var sidebarIsCompact = false
#endif
#if os(iOS)
    @State private var showingPreferences = false
#endif

    var body: some View {
#if os(macOS)
        HStack(spacing: 0) {
            MacNavigationSidebar(
                selection: Binding(
                    get: { selection ?? .dashboard },
                    set: { selection = $0 }
                ),
                isCompact: $sidebarIsCompact
            )
            .frame(width: sidebarIsCompact ? 64 : 224)

            Divider()

            NavigationStack {
                sectionView(selection ?? .dashboard)
                    .id(selection ?? .dashboard)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background { FieldbookPageBackground() }
#else
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppNavigationGroup.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(AppSection.allCases.filter { $0.navigationGroup == group }) { section in
                            Label(section.rawValue, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                }
            }
            .navigationTitle("TroopLedger")
            .scrollContentBackground(.hidden)
            .background { FieldbookPageBackground() }
        } detail: {
            NavigationStack {
                sectionView(selection ?? .dashboard)
            }
        }
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AppearanceToggleButton()
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Preferences", systemImage: "gearshape") { showingPreferences = true }
            }
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView()
        }
#endif
#endif
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .dashboard:
            DashboardView { destination in
                selection = destination
            }
        case .transactions: TransactionListView()
        case .deposits: BatchDepositListView()
        case .reimbursements: ReimbursementListView()
        case .people: PeopleListView()
        case .chargeBatches: RecurringChargeBatchListView()
        case .events: EventListView()
        case .reconcile: ReconciliationView()
        case .budget: BudgetView()
        case .reports: ReportsView()
        case .auditLog: AuditLogView()
        case .accounts: AccountListView()
        case .importData: ImportHubView()
        }
    }
}

#if os(macOS)
private struct MacNavigationSidebar: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: AppSection
    @Binding var isCompact: Bool
    @State private var showingNavigator = false

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ScrollView(.vertical, showsIndicators: false) {
                navigationContent(compact: isCompact)
                    .padding(.horizontal, isCompact ? 8 : 10)
                    .padding(.vertical, 6)
            }
            Divider()
            Button {
                openWindow(id: "preferences")
            } label: {
                if isCompact {
                    Image(systemName: "gearshape")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Preferences")
                } else {
                    Label("Preferences", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, isCompact ? 14 : 12)
            .padding(.top, 10)
            .help("Preferences")

            Button {
                withAnimation(.snappy(duration: 0.22)) { isCompact.toggle() }
            } label: {
                if isCompact {
                    Image(systemName: "sidebar.right")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Expand Sidebar")
                } else {
                    Label("Collapse Sidebar", systemImage: "sidebar.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(isCompact ? 14 : 12)
            .help(isCompact ? "Expand the sidebar" : "Collapse the sidebar")
        }
        .background { FieldbookPageBackground() }
        .animation(.snappy(duration: 0.22), value: isCompact)
    }

    @ViewBuilder
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Button {
                if isCompact {
                    showingNavigator = true
                } else {
                    withAnimation(.snappy(duration: 0.22)) { isCompact = true }
                }
            } label: {
                Image(systemName: isCompact ? "line.3.horizontal" : "sidebar.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCompact ? "Open the navigation menu" : "Collapse the sidebar")
            .accessibilityLabel(isCompact ? "Open the navigation menu" : "Collapse the sidebar")
            .popover(isPresented: $showingNavigator, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TroopLedger")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                    navigationContent(compact: false, dismissesPopover: true)
                        .padding(8)
                }
                .frame(width: 245)
            }

            if !isCompact {
                HStack(spacing: 7) {
                    Image(systemName: "safari.fill")
                        .foregroundStyle(Color.fieldbookAccent)
                    Text("TroopLedger")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func navigationContent(compact: Bool, dismissesPopover: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(AppNavigationGroup.allCases) { group in
                if !compact {
                    Text(group.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(Color.fieldbookMutedInk)
                        .padding(.horizontal, 10)
                        .padding(.top, group == .overview ? 0 : 7)
                        .padding(.bottom, 2)
                } else if group != .overview {
                    Divider().padding(.vertical, 6)
                }

                ForEach(AppSection.allCases.filter { $0.navigationGroup == group }) { section in
                    sidebarButton(section, compact: compact, dismissesPopover: dismissesPopover)
                }
            }
        }
    }

    private func sidebarButton(_ section: AppSection, compact: Bool, dismissesPopover: Bool) -> some View {
        Button {
            selection = section
            if dismissesPopover { showingNavigator = false }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                if !compact {
                    Text(section.rawValue)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 0 : 10)
            .foregroundStyle(selection == section ? Color.fieldbookBackground : Color.primary)
            .background(selection == section ? Color.fieldbookAccent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
    }
}
#endif
