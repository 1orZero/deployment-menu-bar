import SwiftUI
import UIKit

/// Corner radius of every card in the app, as in the design.
let cardCornerRadius: CGFloat = 14

/// White (or dark gray) rounded container of the inset grouped look.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}

/// Uppercase caption above a card.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Hairline between card rows, inset from the leading edge.
struct RowDivider: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, leadingInset)
    }
}

/// Small colored dot followed by a status word, as in the Settings rows.
struct StatusDot: View {
    let text: String
    let color: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(text)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

/// Lays children out left to right, wrapping onto new lines, for the state chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, proposedWidth > maxWidth {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

extension TokenAccount {
    var platform: Deployment.Platform {
        self == .vercel ? .vercel : .cloudflarePages
    }

    var name: String {
        self == .vercel ? "Vercel" : "Cloudflare"
    }
}

extension View {
    /// Inset grouped list styling with the design's background and card colors.
    func appListStyle() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
    }
}

enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
