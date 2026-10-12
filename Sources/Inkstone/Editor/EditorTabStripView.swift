import AppKit
import SwiftUI

final class EditorTabStripModel: ObservableObject {
    struct Item: Identifiable {
        let id: ObjectIdentifier
        var title: String
        var isEdited = false
        var toolTip: String?
    }

    @Published var items: [Item] = []
    @Published var selectedIndex: Int?
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
}

private enum EditorTabStripLayout {
    static let bandHeight: CGFloat = 36
    static let trackHeight: CGFloat = 28
    static let trackPadding: CGFloat = 2
    static let stripInset: CGFloat = 8
    static let trackSpacing: CGFloat = 4
    static let newTabButtonSize: CGFloat = 28
    static let separatorHeight: CGFloat = 16
    static let accessoryWidth: CGFloat = 16
    static let accessoryInset: CGFloat = 5
    static let fontSize: CGFloat = 11
    static let hairline: CGFloat = 0.5
}

struct EditorTabStripView: View {
    @ObservedObject var model: EditorTabStripModel
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: ObjectIdentifier?

    var body: some View {
        HStack(spacing: EditorTabStripLayout.trackSpacing) {
            track
            newTabButton
        }
        .padding(.horizontal, EditorTabStripLayout.stripInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var track: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    itemRow(item, at: index)
                }
            }
            .padding(EditorTabStripLayout.trackPadding)
        }
        .frame(height: EditorTabStripLayout.trackHeight)
        .frame(maxWidth: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .quinaryLabel), lineWidth: EditorTabStripLayout.hairline)
                )
        )
    }

    private func itemRow(_ item: EditorTabStripModel.Item, at index: Int) -> some View {
        let isSelected = model.selectedIndex == index
        let isHovered = hoveredID == item.id
        return ZStack {
            if showsSeparator(before: index, isSelected: isSelected, isHovered: isHovered) {
                HStack {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(
                            width: EditorTabStripLayout.hairline,
                            height: EditorTabStripLayout.separatorHeight
                        )
                    Spacer(minLength: 0)
                }
            }
            Button {
                model.onSelect?(index)
            } label: {
                title(item, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .help(item.toolTip ?? item.title)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected || (isHovered && controlActiveState != .inactive) {
                HStack {
                    EditorTabStripCloseButton { model.onClose?(index) }
                        .environment(\.controlActiveState, controlActiveState)
                    Spacer(minLength: 0)
                }
                .padding(.leading, EditorTabStripLayout.accessoryInset)
            } else if item.isEdited {
                HStack {
                    Circle()
                        .fill(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 6, height: 6)
                        .frame(
                            width: EditorTabStripLayout.accessoryWidth,
                            height: EditorTabStripLayout.accessoryWidth
                        )
                    Spacer(minLength: 0)
                }
                .padding(.leading, EditorTabStripLayout.accessoryInset)
            }
        }
        .frame(minWidth: 96, maxWidth: 220, maxHeight: .infinity)
        .background(surface(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? item.id : nil
        }
    }

    private func title(_ item: EditorTabStripModel.Item, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: EditorTabStripLayout.accessoryWidth)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: EditorTabStripLayout.fontSize))
                .foregroundStyle(titleColor(isSelected: isSelected))
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: EditorTabStripLayout.accessoryWidth)
        }
        .padding(.horizontal, EditorTabStripLayout.accessoryInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func surface(isSelected: Bool, isHovered: Bool) -> some View {
        if isSelected {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlColor))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: EditorTabStripLayout.hairline)
                )
        } else if isHovered, controlActiveState != .inactive {
            Capsule(style: .continuous).fill(Color(nsColor: .tertiarySystemFill))
        } else {
            Color.clear
        }
    }

    private func titleColor(isSelected: Bool) -> Color {
        guard controlActiveState != .inactive else {
            return Color(nsColor: isSelected ? .secondaryLabelColor : .tertiaryLabelColor)
        }
        return Color(nsColor: isSelected ? .labelColor : .secondaryLabelColor)
    }

    private func showsSeparator(before index: Int, isSelected: Bool, isHovered: Bool) -> Bool {
        guard index > 0, model.items.indices.contains(index - 1) else { return false }
        let previous = model.items[index - 1]
        let previousSelected = model.selectedIndex == index - 1
        let previousHovered = hoveredID == previous.id
        return !isSelected && !isHovered && !previousSelected && !previousHovered
    }

    private var newTabButton: some View {
        Button {
            model.onNewTab?()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    Color(nsColor: controlActiveState == .inactive ? .tertiaryLabelColor : .secondaryLabelColor)
                )
                .frame(
                    width: EditorTabStripLayout.newTabButtonSize,
                    height: EditorTabStripLayout.newTabButtonSize
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color(nsColor: .controlColor))
                .shadow(
                    color: .black.opacity(colorScheme == .light ? 0.12 : 0),
                    radius: colorScheme == .light ? 1 : 0,
                    y: colorScheme == .light ? 0.5 : 0
                )
        )
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }
}

private struct EditorTabStripCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    Color(nsColor: controlActiveState == .inactive ? .tertiaryLabelColor : .secondaryLabelColor)
                )
                .frame(
                    width: EditorTabStripLayout.accessoryWidth,
                    height: EditorTabStripLayout.accessoryWidth
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(isHovering ? Color(nsColor: .quaternarySystemFill) : .clear))
        .onHover { isHovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}
