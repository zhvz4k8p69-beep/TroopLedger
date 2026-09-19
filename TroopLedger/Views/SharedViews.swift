import SwiftUI

struct MoneyText: View {
    let cents: Int64
    var colorBySign = false

    var body: some View {
        Text(Money.currency(cents: cents))
            .monospacedDigit()
            .foregroundStyle(colorBySign ? signColor : .primary)
    }

    private var signColor: Color {
        if cents > 0 { return .fieldbookPositive }
        if cents < 0 { return .fieldbookDanger }
        return .secondary
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.fieldbookRaisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        }
    }
}

struct EmptyMessage: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

struct TroopReportHeader: View {
    let profile: TroopProfileRecord?
    let reportTitle: String
    var subtitle: String? = nil

    private var identity: TroopReportIdentity { TroopReportIdentity(profile: profile) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            FieldbookActivityEmblem(systemImage: "flag.fill", size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(identity.formalName)
                    .font(.headline)
                if !identity.organizationLine.isEmpty {
                    Text(identity.organizationLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !identity.mailingAddress.isEmpty {
                    Text(identity.mailingAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !identity.treasurerLine.isEmpty {
                    Text(identity.treasurerLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(reportTitle)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

struct AmountField: View {
    let title: String
    @Binding var text: String
    /// The decimal pad has no minus key, so fields that may legitimately hold a negative value (an overdrawn
    /// opening balance) need a keyboard that can type one.
    var allowsNegative = false

    var body: some View {
        TextField(title, text: $text)
#if os(iOS)
            .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
#endif
    }
}

private struct MacPageToolbar<Actions: View>: View {
    let title: String
    let actions: Actions

    init(title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 20)
            HStack(spacing: 8) {
                actions
                Divider().frame(height: 18)
                AppearanceToggleButton()
                    .labelStyle(.iconOnly)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(Color.fieldbookSurface.opacity(0.96))
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension View {
#if os(macOS)
    /// Stacks the page toolbar above the content instead of using `safeAreaInset(edge: .top)`. With the inset,
    /// a `List` extended under the toolbar and its section-header cells were sometimes measured while sitting
    /// in that top safe area, so the first pinned header came out taller by the inset (~65pt of blank space
    /// between the header and its first row on pushed screens). Keeping the toolbar out of the list's safe
    /// area removes the miscalculation. The content is proposed the full remaining area so short, non-scrolling
    /// pages lay out exactly as they did under the inset.
    private func macPage<Toolbar: View>(@ViewBuilder toolbar: () -> Toolbar) -> some View {
        VStack(spacing: 0) {
            toolbar()
            frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
#endif

    @ViewBuilder
    func pageToolbar<Actions: View>(title: String, @ViewBuilder actions: () -> Actions) -> some View {
#if os(macOS)
        macPage { MacPageToolbar(title: title, actions: actions) }
#else
        navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    actions()
                }
            }
#endif
    }

    @ViewBuilder
    func pageHeader(title: String) -> some View {
#if os(macOS)
        macPage { MacPageToolbar(title: title) { EmptyView() } }
#else
        navigationTitle(title)
#endif
    }
}
