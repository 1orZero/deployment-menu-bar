import SwiftUI

/// Screen A: today's totals, platform issues and the deployment rows, grouped like the Mac menu's layout setting.
struct DeploymentsView: View {
    enum PlatformFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case vercel = "Vercel"
        case cloudflare = "Cloudflare"

        var id: String { rawValue }

        func includes(_ deployment: Deployment) -> Bool {
            switch self {
            case .all: true
            case .vercel: deployment.platform.menuPlatform == .vercel
            case .cloudflare: deployment.platform.menuPlatform == .cloudflare
            }
        }
    }

    struct RowSection: Identifiable {
        let id: String
        let title: String
        let deployments: [Deployment]
    }

    @EnvironmentObject private var feed: DeploymentFeed
    @State private var filter: PlatformFilter = .all
    @State private var layout = PreferencesStore.shared.current.general.menuLayout
    @State private var isRefreshing = false

    var body: some View {
        let snapshot = feed.snapshot
        ScrollView {
            VStack(spacing: 16) {
                summaryTiles(snapshot.todayCounts())

                ForEach(snapshot.issues, id: \.self) { issue in
                    IssueBanner(message: issue)
                }

                Picker("Platform", selection: $filter) {
                    ForEach(PlatformFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)

                let sections = sections(for: snapshot.deployments)
                if sections.isEmpty {
                    Text(MenuComposition.noDeploymentsMessage)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    ForEach(sections) { section in
                        VStack(spacing: 8) {
                            SectionTitle(text: section.title)
                            Card {
                                ForEach(Array(section.deployments.enumerated()), id: \.element.id) { index, deployment in
                                    if index > 0 {
                                        RowDivider()
                                    }
                                    NavigationLink(value: deployment.id) {
                                        DeploymentRow(deployment: deployment)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if let fetchedAt = snapshot.fetchedAt {
                    Text("Last updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Palette.background)
        .navigationTitle("Deployments")
        .refreshable { await feed.refreshNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        isRefreshing = true
                        await feed.refreshNow()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh")
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: PreferencesStore.didChangeNotification).receive(on: RunLoop.main)
        ) { _ in
            layout = PreferencesStore.shared.current.general.menuLayout
        }
    }

    private func summaryTiles(_ counts: StateCounts) -> some View {
        HStack(spacing: 10) {
            SummaryTile(title: "Building", value: counts.building, style: StateStyle(.building))
            SummaryTile(title: "Ready", value: counts.ready, style: StateStyle(.ready))
            SummaryTile(title: "Failed", value: counts.failed, style: StateStyle(.error))
        }
    }

    private func sections(for deployments: [Deployment]) -> [RowSection] {
        let rows = deployments.filter(filter.includes)
        guard !rows.isEmpty else { return [] }
        switch layout {
        case .byPlatform:
            return [MenuPlatform.vercel, .cloudflare].compactMap { platform in
                let platformRows = rows.filter { $0.platform.menuPlatform == platform }
                guard !platformRows.isEmpty else { return nil }
                return RowSection(id: platform.name, title: platform.name, deployments: platformRows)
            }
        case .byTime:
            let calendar = Calendar.current
            var sections: [RowSection] = []
            for deployment in rows {
                let day = calendar.startOfDay(for: deployment.createdAt)
                let id = day.ISO8601Format()
                if let last = sections.last, last.id == id {
                    sections[sections.count - 1] = RowSection(
                        id: id, title: last.title, deployments: last.deployments + [deployment]
                    )
                } else {
                    sections.append(RowSection(id: id, title: Self.dayTitle(day, calendar: calendar), deployments: [deployment]))
                }
            }
            return sections
        }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

private struct SummaryTile: View {
    let title: String
    let value: Int
    let style: StateStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
                    .foregroundStyle(Palette.textSecondary)
            } icon: {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
            }
            .font(.subheadline)
            .lineLimit(1)

            Text("\(value)")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(style.color)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct IssueBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .foregroundStyle(Palette.warningText)
        .padding(14)
        .background(Palette.warningBackground, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}

struct DeploymentRow: View {
    let deployment: Deployment

    var body: some View {
        let style = StateStyle(deployment.state)
        HStack(spacing: 12) {
            PlatformBadge(platform: deployment.platform)

            VStack(alignment: .leading, spacing: 3) {
                Text(deployment.projectName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !deployment.metaLine.isEmpty {
                    Text(deployment.metaLine)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Label(style.label, systemImage: style.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.color)
                    .labelStyle(TightLabelStyle())
                Text(DeploymentFormat.time(deployment.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
