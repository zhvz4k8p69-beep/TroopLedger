import SwiftUI

#if os(macOS)
import AppKit
#endif

enum AppAppearance: String, CaseIterable, Identifiable, Hashable {
    case light
    case dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Fieldbook Day"
        case .dark: "Campsite Night"
        }
    }

    var shortTitle: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var toggled: AppAppearance {
        self == .light ? .dark : .light
    }

    static func resolved(storedRawValue: String, fallback: ColorScheme) -> AppAppearance {
        AppAppearance(rawValue: storedRawValue) ?? (fallback == .dark ? .dark : .light)
    }

    static func toggledRawValue(storedRawValue: String, fallback: ColorScheme) -> String {
        resolved(storedRawValue: storedRawValue, fallback: fallback).toggled.rawValue
    }

#if os(macOS)
    @MainActor
    static var currentMacSystemScheme: ColorScheme {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }
#endif
}

extension Color {
    static let fieldbookAccent = Color("FieldbookAccent")
    static let fieldbookBackground = Color("FieldbookBackground")
    static let fieldbookSurface = Color("FieldbookSurface")
    static let fieldbookRaisedSurface = Color("FieldbookRaisedSurface")
    static let fieldbookBorder = Color("FieldbookBorder")
    static let fieldbookInk = Color("FieldbookInk")
    static let fieldbookMutedInk = Color("FieldbookMutedInk")
    static let fieldbookContour = Color("FieldbookContour")
    static let fieldbookInfo = Color("FieldbookInfo")
    static let fieldbookPositive = Color("FieldbookPositive")
    static let fieldbookWarning = Color("FieldbookWarning")
    static let fieldbookDanger = Color("FieldbookDanger")
}

private struct TroopLedgerAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var storedAppearance = ""

    private var preferredScheme: ColorScheme? {
        AppAppearance(rawValue: storedAppearance)?.colorScheme
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preferredScheme)
            .tint(.fieldbookAccent)
    }
}

extension View {
    func troopLedgerAppearance() -> some View {
        modifier(TroopLedgerAppearanceModifier())
    }
}

struct AppearanceToggleButton: View {
    @AppStorage(AppAppearance.storageKey) private var storedAppearance = ""
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: AppAppearance {
        AppAppearance.resolved(storedRawValue: storedAppearance, fallback: colorScheme)
    }

    private var destination: AppAppearance { appearance.toggled }

    var body: some View {
        Button {
            storedAppearance = destination.rawValue
        } label: {
            Label("Switch to \(destination.shortTitle) Mode", systemImage: destination.systemImage)
        }
        .help("Switch to \(destination.title) (Command-D)")
        .accessibilityLabel("Switch to \(destination.shortTitle) Mode")
#if os(iOS)
        .keyboardShortcut("d", modifiers: .command)
#endif
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var storedAppearance = ""
    @Environment(\.colorScheme) private var colorScheme
    var showsDismissButton = true
    @Environment(\.dismiss) private var dismiss

    private var selection: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance.resolved(storedRawValue: storedAppearance, fallback: colorScheme) },
            set: { storedAppearance = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: selection) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Label(appearance.title, systemImage: appearance.systemImage)
                                .tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Fieldbook Day uses parchment, paper, and Scouts BSA olive. Campsite Night uses deep spruce, canvas, and warm tan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Keyboard") {
                    LabeledContent("Toggle Light and Dark", value: "⌘D")
                    Text("The shortcut works from anywhere in the main Mac window. On iPad and iPhone it is also available with a connected hardware keyboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Design Language") {
                    Label("Fieldbook paper and topographic lines", systemImage: "map")
                    Label("Original outdoor activity emblems", systemImage: "tent.2")
                    Label("Native, legible financial controls", systemImage: "checkmark.seal")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Appearance")
            .toolbar {
#if os(iOS)
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
#endif
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
#endif
    }
}

struct FieldbookPageBackground: View {
    var body: some View {
        ZStack {
            Color.fieldbookBackground
            TopographicContourMap()
                .mask {
                    LinearGradient(
                        colors: [.black.opacity(0.28), .black, .black.opacity(0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .accessibilityHidden(true)
    }
}

private struct TopographicContourMap: View {
    private let minorLevels: [Double] = [
        0.10, 0.18, 0.26, 0.42, 0.50, 0.58, 0.74,
        0.82, 0.90, 1.06, 1.14, 1.22, 1.38, 1.46
    ]
    private let indexLevels: [Double] = [0.34, 0.66, 0.98, 1.30]

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let terrain = TopographicTerrain(size: size)

            context.stroke(
                terrain.contourPath(levels: minorLevels),
                with: .color(Color.fieldbookContour.opacity(0.52)),
                style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                terrain.contourPath(levels: indexLevels),
                with: .color(Color.fieldbookContour.opacity(0.82)),
                style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }
}

private struct TopographicTerrain {
    private struct Sample {
        let point: CGPoint
        let elevation: Double
    }

    private let size: CGSize
    private let columns = 96
    private let rows = 72
    private let elevations: [Double]

    init(size: CGSize) {
        self.size = size
        var samples: [Double] = []
        samples.reserveCapacity((columns + 1) * (rows + 1))

        for row in 0...rows {
            for column in 0...columns {
                let x = Double(column) / Double(columns)
                let y = Double(row) / Double(rows)
                samples.append(Self.elevation(x: x, y: y))
            }
        }
        elevations = samples
    }

    func contourPath(levels: [Double]) -> Path {
        var path = Path()

        for level in levels {
            for row in 0..<rows {
                for column in 0..<columns {
                    appendSegments(
                        for: [
                            sample(column: column, row: row),
                            sample(column: column + 1, row: row),
                            sample(column: column + 1, row: row + 1),
                            sample(column: column, row: row + 1)
                        ],
                        level: level,
                        to: &path
                    )
                }
            }
        }

        return path
    }

    private func sample(column: Int, row: Int) -> Sample {
        let point = CGPoint(
            x: size.width * CGFloat(column) / CGFloat(columns),
            y: size.height * CGFloat(row) / CGFloat(rows)
        )
        return Sample(point: point, elevation: elevations[row * (columns + 1) + column])
    }

    private func appendSegments(for corners: [Sample], level: Double, to path: inout Path) {
        let edgeCorners = [(0, 1), (1, 2), (2, 3), (3, 0)]
        var intersections: [(edge: Int, point: CGPoint)] = []

        for (edge, pair) in edgeCorners.enumerated() {
            let start = corners[pair.0]
            let end = corners[pair.1]
            guard (start.elevation >= level) != (end.elevation >= level) else { continue }

            let range = end.elevation - start.elevation
            let fraction = range == 0 ? 0.5 : (level - start.elevation) / range
            intersections.append((
                edge,
                CGPoint(
                    x: start.point.x + CGFloat(fraction) * (end.point.x - start.point.x),
                    y: start.point.y + CGFloat(fraction) * (end.point.y - start.point.y)
                )
            ))
        }

        if intersections.count == 2 {
            addSegment(from: intersections[0].point, to: intersections[1].point, in: &path)
            return
        }

        guard intersections.count == 4 else { return }
        let caseIndex = corners.enumerated().reduce(0) { value, item in
            value | (item.element.elevation >= level ? (1 << item.offset) : 0)
        }
        let centerIsHigh = corners.map(\.elevation).reduce(0, +) / 4 >= level
        let pairs: [(Int, Int)]

        if (caseIndex == 5 && centerIsHigh) || (caseIndex == 10 && !centerIsHigh) {
            pairs = [(0, 1), (2, 3)]
        } else {
            pairs = [(0, 3), (1, 2)]
        }

        for pair in pairs {
            addSegment(from: intersections[pair.0].point, to: intersections[pair.1].point, in: &path)
        }
    }

    private func addSegment(from start: CGPoint, to end: CGPoint, in path: inout Path) {
        path.move(to: start)
        path.addLine(to: end)
    }

    private static func elevation(x: Double, y: Double) -> Double {
        let warpedX = x + 0.018 * sin(y * .pi * 5.2) + 0.010 * sin((x + y) * .pi * 7.0)
        let warpedY = y + 0.020 * sin(x * .pi * 4.4) - 0.009 * cos((x - y) * .pi * 6.0)

        let mainSummit = gaussian(x: warpedX, y: warpedY, centerX: 0.76, centerY: 0.25, spreadX: 0.22, spreadY: 0.18, height: 1.34)
        let eastShoulder = gaussian(x: warpedX, y: warpedY, centerX: 0.93, centerY: 0.39, spreadX: 0.16, spreadY: 0.20, height: 0.58)
        let southwestSummit = gaussian(x: warpedX, y: warpedY, centerX: 0.20, centerY: 0.77, spreadX: 0.18, spreadY: 0.22, height: 1.02)
        let connectingRidge = gaussian(x: warpedX, y: warpedY, centerX: 0.48, centerY: 0.61, spreadX: 0.34, spreadY: 0.11, height: 0.34)
        let saddle = gaussian(x: warpedX, y: warpedY, centerX: 0.54, centerY: 0.49, spreadX: 0.16, spreadY: 0.13, height: -0.19)
        let naturalVariation = 0.022 * sin((x * 9.0 + y * 4.0) * .pi) * cos((y * 7.0 - x * 2.0) * .pi)

        return mainSummit + eastShoulder + southwestSummit + connectingRidge + saddle + naturalVariation
    }

    private static func gaussian(
        x: Double,
        y: Double,
        centerX: Double,
        centerY: Double,
        spreadX: Double,
        spreadY: Double,
        height: Double
    ) -> Double {
        let horizontal = (x - centerX) / spreadX
        let vertical = (y - centerY) / spreadY
        return height * exp(-0.5 * (horizontal * horizontal + vertical * vertical))
    }
}

struct FieldbookPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fieldbookSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.fieldbookBorder, lineWidth: 1)
            }
            .shadow(
                color: colorScheme == .light ? Color.black.opacity(0.035) : .clear,
                radius: 8,
                y: 2
            )
    }
}

struct FieldbookProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(Color.fieldbookBackground)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.fieldbookAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.48)
    }
}

extension ButtonStyle where Self == FieldbookProminentButtonStyle {
    static var fieldbookProminent: FieldbookProminentButtonStyle { FieldbookProminentButtonStyle() }
}

enum ScoutMotion {
    static func shouldCelebrateTransition(previous: Int?, current: Int, target: Int) -> Bool {
        guard let previous, target > 0 else { return false }
        return previous < target && current >= target
    }
}

struct ScoutTrailProgress: View {
    let completed: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedCompleted: Int { min(max(completed, 0), total) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(total, 0), id: \.self) { index in
                marker(at: index)

                if index < total - 1 {
                    Capsule()
                        .fill(index < clampedCompleted - 1 ? Color.fieldbookAccent : Color.fieldbookBorder)
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                }
            }
        }
        .frame(height: 28)
        .animation(reduceMotion ? nil : .snappy(duration: 0.34), value: clampedCompleted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monthly close trail")
        .accessibilityValue("\(clampedCompleted) of \(total) complete")
    }

    private func marker(at index: Int) -> some View {
        let isComplete = index < clampedCompleted
        let isFinal = index == total - 1

        return ZStack {
            Circle()
                .fill(isComplete ? Color.fieldbookAccent : Color.fieldbookRaisedSurface)
            Circle()
                .stroke(isComplete ? Color.fieldbookAccent : Color.fieldbookBorder, lineWidth: 2)
            Image(systemName: isFinal && clampedCompleted == total ? "flag.fill" : (isComplete ? "checkmark" : "circle.fill"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isComplete ? Color.fieldbookBackground : Color.fieldbookBorder)
        }
        .frame(width: 24, height: 24)
        .scaleEffect(!reduceMotion && isComplete ? 1.0 : 0.92)
    }
}

struct ReconciliationCompass: View {
    let differenceCents: Int64?
    let isReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needleRotation: Double {
        guard !isReady else { return 0 }
        return (differenceCents ?? 0) < 0 ? -38 : 38
    }

    var body: some View {
        ZStack {
            Circle()
                .fill((isReady ? Color.fieldbookPositive : Color.fieldbookWarning).opacity(0.12))
            Circle()
                .stroke(isReady ? Color.fieldbookPositive : Color.fieldbookWarning, lineWidth: 1.5)
            Image(systemName: "location.north.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isReady ? Color.fieldbookPositive : Color.fieldbookWarning)
                .rotationEffect(.degrees(reduceMotion ? 0 : needleRotation))
        }
        .frame(width: 28, height: 28)
        .animation(reduceMotion ? nil : .spring(duration: 0.48, bounce: 0.24), value: isReady)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: needleRotation)
        .accessibilityHidden(true)
    }
}

private struct ScoutMilestoneStamp: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let badgeSystemImage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasLanded = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.fieldbookAccent)
                    .frame(width: 50, height: 50)
                    .background(Color.fieldbookRaisedSurface, in: Circle())
                    .overlay { Circle().stroke(Color.fieldbookAccent.opacity(0.55), lineWidth: 2) }

                if let badgeSystemImage {
                    Image(systemName: badgeSystemImage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.fieldbookBackground)
                        .padding(5)
                        .background(Color.fieldbookPositive, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.fieldbookSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.fieldbookPositive.opacity(0.72), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
        .scaleEffect(reduceMotion || hasLanded ? 1 : 0.76)
        .rotationEffect(.degrees(reduceMotion || hasLanded ? 0 : -5))
        .opacity(hasLanded ? 1 : 0)
        .onAppear {
            if reduceMotion {
                hasLanded = true
            } else {
                withAnimation(.spring(duration: 0.46, bounce: 0.3)) {
                    hasLanded = true
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ScoutMilestoneOverlayModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let subtitle: String?
    let systemImage: String
    let badgeSystemImage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ScoutMilestoneStamp(
                        title: title,
                        subtitle: subtitle,
                        systemImage: systemImage,
                        badgeSystemImage: badgeSystemImage
                    )
                    .padding(24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(100)
                }
            }
            .task(id: isPresented) {
                guard isPresented else { return }
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.24)) {
                    isPresented = false
                }
            }
    }
}

extension View {
    func scoutMilestoneOverlay(
        isPresented: Binding<Bool>,
        title: String,
        subtitle: String? = nil,
        systemImage: String = "checkmark.seal.fill",
        badgeSystemImage: String? = "checkmark"
    ) -> some View {
        modifier(ScoutMilestoneOverlayModifier(
            isPresented: isPresented,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            badgeSystemImage: badgeSystemImage
        ))
    }
}

struct FieldbookActivityEmblem: View {
    let systemImage: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.40, weight: .semibold))
            .foregroundStyle(Color.fieldbookAccent)
            .frame(width: size, height: size)
            .background(Color.fieldbookRaisedSurface, in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.fieldbookAccent.opacity(0.52), lineWidth: 2)
                    .padding(2)
            }
            .overlay {
                Circle().stroke(Color.fieldbookBorder, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct FieldbookDateMarker: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)))
                .font(.caption2.bold())
                .textCase(.uppercase)
            Text(date.formatted(.dateTime.day()))
                .font(.title3.bold())
        }
        .foregroundStyle(Color.fieldbookAccent)
        .frame(width: 45, height: 48)
        .background(Color.fieldbookRaisedSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.fieldbookBorder, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

enum FieldbookActivityIcon {
    static func systemImage(for eventName: String, classification: EventClassification) -> String {
        let name = eventName.lowercased()
        if name.contains("camp") || name.contains("overnight") { return "tent.2.fill" }
        if name.contains("hike") || name.contains("trail") || name.contains("backpack") { return "figure.hiking" }
        if name.contains("canoe") || name.contains("kayak") || name.contains("swim") || name.contains("water") { return "water.waves" }
        if name.contains("cook") || name.contains("dutch oven") || name.contains("fire") { return "flame.fill" }
        if name.contains("service") || name.contains("conservation") || name.contains("cleanup") { return "leaf.fill" }
        if name.contains("orienteer") || name.contains("navigation") { return "safari.fill" }

        return switch classification {
        case .troop: "flag.fill"
        case .district: "map.fill"
        case .council: "building.2.fill"
        case .national: "star.fill"
        }
    }
}
