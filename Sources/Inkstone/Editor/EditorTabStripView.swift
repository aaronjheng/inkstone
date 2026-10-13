import AppKit
import SwiftUI

final class EditorTabStripModel: ObservableObject {
    struct Item: Identifiable {
        let id: ObjectIdentifier
        var title: String
        var isEdited = false
        var toolTip: String?
    }

    struct RevealRequest: Equatable {
        let id: ObjectIdentifier
        let counter: Int
    }

    @Published var items: [Item] = []
    @Published var selectedIndex: Int?
    @Published var revealRequest: RevealRequest?
    @Published var scrollRequest: RevealRequest?
    @Published var trackContentOffset: CGFloat = EditorTabStripLayout.trackPadding
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onCloseAll: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onMoveLeft: ((Int) -> Void)?
    var onMoveRight: ((Int) -> Void)?
    var onMoveToNewWindow: ((Int) -> Void)?
    var onTearOff: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var revealCounter = 0
    private var scrollCounter = 0

    func requestReveal(id: ObjectIdentifier) {
        revealCounter += 1
        revealRequest = RevealRequest(id: id, counter: revealCounter)
    }

    func requestScrollToLeading(id: ObjectIdentifier) {
        scrollCounter += 1
        scrollRequest = RevealRequest(id: id, counter: scrollCounter)
    }
}

enum EditorTabStripLayout {
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
    /// Measured off `NSTabBar`: tabs take an equal share of the track down to this width,
    /// and below it the track scrolls instead of squeezing labels.
    static let minimumTabWidth: CGFloat = 120
    static let reorderThreshold: CGFloat = 4
    static let tearOffThreshold: CGFloat = 44
    static let autoscrollMargin: CGFloat = 24
    static let autoscrollInterval: TimeInterval = 0.05
    static let trackSpace = "EditorTabStrip.track"
    static let viewportSpace = "EditorTabStrip.viewport"
    static let reorderDuration: Double = 0.18

    static func tabWidth(containerWidth: CGFloat, count: Int) -> CGFloat {
        let count = max(count, 1)
        let available = containerWidth - 2 * trackPadding
        guard available > 0 else { return minimumTabWidth }
        return max(available / CGFloat(count), minimumTabWidth)
    }

    static func viewportWidth(containerWidth: CGFloat) -> CGFloat {
        containerWidth - 2 * stripInset - newTabButtonSize - trackSpacing
    }
}

private struct TabDrag {
    let id: ObjectIdentifier
    var targetIndex: Int
    var translation: CGSize
}

private struct TrackOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat { EditorTabStripLayout.trackPadding }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private final class TabEscapeMonitor {
    var onCancel: (() -> Void)?
    private var monitor: Any?

    func arm() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let onCancel = self?.onCancel else { return event }
            onCancel()
            return nil
        }
    }

    func disarm() {
        onCancel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private final class TabAutoScroller: @unchecked Sendable {
    var onTick: (() -> Void)?
    private var timer: Timer?

    func start() {
        stop()
        let timer = Timer(
            timeInterval: EditorTabStripLayout.autoscrollInterval, repeats: true
        ) { [weak self] _ in
            self?.onTick?()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onTick = nil
    }

    deinit {
        timer?.invalidate()
    }
}

struct EditorTabStripView: View {
    @ObservedObject var model: EditorTabStripModel
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var hoveredID: ObjectIdentifier?
    @State private var pressIndex: Int?
    @State private var drag: TabDrag?
    @State private var dragCancelled = false
    @State private var escapeMonitor = TabEscapeMonitor()
    @State private var isTearingOff = false
    @State private var pressContentX: CGFloat = 0
    @State private var pointerContentX: CGFloat = 0
    @State private var autoScrollShift: CGFloat = 0
    @State private var autoScroller = TabAutoScroller()
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: EditorTabStripLayout.trackSpacing) {
                track
                newTabButton
            }
        }
        .padding(.horizontal, EditorTabStripLayout.stripInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) { tearGhost }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab Strip")
        .accessibilityAddTraits(.isTabBar)
        .accessibilityHint("Switch between open document tabs")
    }

    private var track: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            itemRow(item, at: index, width: tabWidth(containerWidth: geometry.size.width))
                                .id(item.id)
                        }
                    }
                    .coordinateSpace(name: EditorTabStripLayout.trackSpace)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TrackOffsetKey.self,
                                value: geo.frame(in: .named(EditorTabStripLayout.viewportSpace)).minX
                            )
                        }
                    )
                    .padding(EditorTabStripLayout.trackPadding)
                }
                .coordinateSpace(name: EditorTabStripLayout.viewportSpace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(TrackOffsetKey.self) { model.trackContentOffset = $0 }
                .onChange(of: model.revealRequest) { _, request in
                    reveal(request, proxy: proxy, trackWidth: geometry.size.width)
                }
                .onChange(of: model.scrollRequest) { _, request in
                    guard let request else { return }
                    proxy.scrollTo(request.id, anchor: .leading)
                }
                .onAppear { viewportWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in viewportWidth = width }
            }
        }
        .frame(height: EditorTabStripLayout.trackHeight)
        .frame(maxWidth: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .quinaryLabelColor), lineWidth: EditorTabStripLayout.hairline)
                )
        )
    }

    private func tabWidth(containerWidth: CGFloat) -> CGFloat {
        EditorTabStripLayout.tabWidth(containerWidth: containerWidth, count: model.items.count)
    }

    private func itemRow(_ item: EditorTabStripModel.Item, at index: Int, width: CGFloat) -> some View {
        let isSelected = model.selectedIndex == index
        let isHovered = hoveredID == item.id
        let showsClose = (isHovered && controlActiveState != .inactive) || (isSelected && !item.isEdited)
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
            title(item, isSelected: isSelected)
                .gesture(tabDragGesture(id: item.id, index: index, width: width))
                .help(item.toolTip ?? item.title)

            if showsClose {
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
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(surface(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            guard drag == nil else { return }
            hoveredID = hovering ? item.id : nil
        }
        .zIndex(drag?.id == item.id ? 1 : 0)
        .offset(x: dragOffsetX(at: index, width: width), y: dragOffsetY(at: index))
        .opacity(isTearingOff && drag?.id == item.id ? 0 : 1)
        .animation(.easeOut(duration: EditorTabStripLayout.reorderDuration), value: drag?.targetIndex)
        .contextMenu {
            Button("Close") { model.onClose?(index) }
            Button("Close Others") { model.onCloseOthers?(index) }
            Button("Close All") { model.onCloseAll?() }
            Divider()
            Button("Move Left") { model.onMoveLeft?(index) }
                .disabled(index == 0)
            Button("Move Right") { model.onMoveRight?(index) }
                .disabled(index >= model.items.count - 1)
            Button("Move to New Window") { model.onMoveToNewWindow?(index) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue("\(index + 1) of \(model.items.count)")
        .accessibilityAction { model.onSelect?(index) }
        .accessibilityAction(named: Text("Close Tab")) { model.onClose?(index) }
    }

    private func tabDragGesture(id: ObjectIdentifier, index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(EditorTabStripLayout.trackSpace))
            .onChanged { value in
                guard !dragCancelled else { return }
                if pressIndex == nil { pressIndex = index }
                guard pressIndex == index else { return }
                pointerContentX = value.location.x
                if drag == nil {
                    let moved = hypot(value.translation.width, value.translation.height)
                    guard moved >= EditorTabStripLayout.reorderThreshold else { return }
                    pressContentX = value.location.x - value.translation.width
                    drag = TabDrag(id: id, targetIndex: index, translation: value.translation)
                    if model.selectedIndex != index { model.onSelect?(index) }
                    armEscapeMonitor()
                    autoScroller.start()
                    autoScroller.onTick = { autoScrollTick() }
                }
                applyDragTranslation(
                    dragX: pointerContentX - pressContentX,
                    height: value.translation.height,
                    width: width
                )
            }
            .onEnded { value in
                defer {
                    pressIndex = nil
                    drag = nil
                    dragCancelled = false
                    isTearingOff = false
                    // The offset is derived per drag; leaving it set made the next
                    // drag's first autoscroll tick jump to the previous drag's tab.
                    autoScrollShift = EditorTabStripLayout.trackPadding
                    autoScroller.stop()
                    escapeMonitor.disarm()
                }
                if dragCancelled {
                    hoveredID = nil
                    return
                }
                if let drag {
                    if isTearingOff {
                        if let fromIndex = model.items.firstIndex(where: { $0.id == drag.id }) {
                            model.onTearOff?(fromIndex)
                        }
                        hoveredID = nil
                    } else {
                        commit(drag, at: value.location.x, width: width)
                    }
                    return
                }
                let releaseX = value.location.x
                guard releaseX >= CGFloat(index) * width, releaseX <= CGFloat(index + 1) * width else {
                    return
                }
                model.onSelect?(index)
            }
    }

    private func commit(_ drag: TabDrag, at dropX: CGFloat, width: CGFloat) {
        if let fromIndex = model.items.firstIndex(where: { $0.id == drag.id }), width > 0 {
            let steps = Int((drag.translation.width / width).rounded())
            let upper = max(model.items.count - 1, 0)
            let target = min(max(fromIndex + steps, 0), upper)
            if target != fromIndex {
                model.onMove?(fromIndex, target)
            }
        }
        let count = CGFloat(model.items.count)
        if dropX >= 0, dropX < count * width, count > 0 {
            let dropIndex = Int(dropX / width)
            hoveredID = model.items.indices.contains(dropIndex) ? model.items[dropIndex].id : nil
        } else {
            hoveredID = nil
        }
    }

    private func applyDragTranslation(dragX: CGFloat, height: CGFloat, width: CGFloat) {
        guard var drag, width > 0 else { return }
        drag.translation = CGSize(width: dragX, height: height)
        if abs(height) >= EditorTabStripLayout.tearOffThreshold {
            isTearingOff = true
        } else if isTearingOff {
            isTearingOff = false
        }
        if let fromIndex = model.items.firstIndex(where: { $0.id == drag.id }) {
            if isTearingOff {
                drag.targetIndex = fromIndex
            } else {
                let steps = Int((dragX / width).rounded())
                let upper = max(model.items.count - 1, 0)
                drag.targetIndex = min(max(fromIndex + steps, 0), upper)
            }
        }
        self.drag = drag
    }

    private func dragOffsetX(at index: Int, width: CGFloat) -> CGFloat {
        guard let drag, let fromIndex = model.items.firstIndex(where: { $0.id == drag.id }) else {
            return 0
        }
        if isTearingOff { return index == fromIndex ? drag.translation.width : 0 }
        if index == fromIndex { return drag.translation.width }
        if drag.targetIndex > fromIndex, index > fromIndex, index <= drag.targetIndex {
            return -width
        }
        if drag.targetIndex < fromIndex, index < fromIndex, index >= drag.targetIndex {
            return width
        }
        return 0
    }

    private func dragOffsetY(at index: Int) -> CGFloat {
        guard let drag, isTearingOff else { return 0 }
        guard let fromIndex = model.items.firstIndex(where: { $0.id == drag.id }) else { return 0 }
        return index == fromIndex ? drag.translation.height : 0
    }

    private func armEscapeMonitor() {
        escapeMonitor.onCancel = {
            drag = nil
            dragCancelled = true
        }
        escapeMonitor.arm()
    }

    private func reveal(
        _ request: EditorTabStripModel.RevealRequest?,
        proxy: ScrollViewProxy,
        trackWidth: CGFloat
    ) {
        guard let request, let index = model.items.firstIndex(where: { $0.id == request.id }) else {
            return
        }
        let width = EditorTabStripLayout.tabWidth(
            containerWidth: trackWidth, count: model.items.count
        )
        let tabX = CGFloat(index) * width
        let leading = -model.trackContentOffset
        if tabX < leading || tabX + width > leading + trackWidth {
            proxy.scrollTo(request.id)
        }
    }

    private func autoScrollTick() {
        guard let drag, !dragCancelled, !isTearingOff, viewportWidth > 0 else { return }
        let count = model.items.count
        guard count > 0 else { return }
        let width = EditorTabStripLayout.tabWidth(containerWidth: viewportWidth, count: count)
        let contentWidth = 2 * EditorTabStripLayout.trackPadding + CGFloat(count) * width
        guard contentWidth > viewportWidth else { return }
        let viewportX = pointerContentX + EditorTabStripLayout.trackPadding - autoScrollShift
        let atLeading = viewportX < EditorTabStripLayout.autoscrollMargin
        let atTrailing = viewportX > viewportWidth - EditorTabStripLayout.autoscrollMargin
        guard atLeading || atTrailing else { return }
        let currentK = max(
            0,
            Int(((autoScrollShift - EditorTabStripLayout.trackPadding) / width).rounded())
        )
        let targetK = atLeading ? currentK - 1 : currentK + 1
        guard targetK >= 0, targetK < count else { return }
        let targetID = model.items[targetK].id
        autoScrollShift = EditorTabStripLayout.trackPadding + CGFloat(targetK) * width
        pointerContentX += atLeading ? -width : width
        model.requestScrollToLeading(id: targetID)
        applyDragTranslation(
            dragX: pointerContentX - pressContentX,
            height: drag.translation.height,
            width: width
        )
    }

    @ViewBuilder
    private var tearGhost: some View {
        if let drag, isTearingOff, viewportWidth > 0,
            let fromIndex = model.items.firstIndex(where: { $0.id == drag.id })
        {
            let width = EditorTabStripLayout.tabWidth(
                containerWidth: viewportWidth, count: model.items.count
            )
            let ghostX =
                EditorTabStripLayout.stripInset + model.trackContentOffset
                + CGFloat(fromIndex) * width + drag.translation.width
            let ghostY = EditorTabStripLayout.trackPadding + drag.translation.height
            ZStack {
                surface(isSelected: true, isHovered: false)
                title(model.items[fromIndex], isSelected: true)
            }
            .frame(
                width: width,
                height: EditorTabStripLayout.trackHeight - 2 * EditorTabStripLayout.trackPadding
            )
            .offset(x: ghostX, y: ghostY)
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
        guard drag == nil else { return false }
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
        .newTabSurface(isLight: colorScheme == .light, prefersSolid: prefersSolidSurfaces)
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }

    private var prefersSolidSurfaces: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }
}

/// The "+" surface: glass, which the container behind it feeds; falling back to the opaque
/// control circle where accessibility asks for solid surfaces.
extension View {
    @ViewBuilder
    fileprivate func newTabSurface(isLight: Bool, prefersSolid: Bool) -> some View {
        if prefersSolid {
            background(
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .shadow(
                        color: .black.opacity(isLight ? 0.12 : 0),
                        radius: isLight ? 1 : 0,
                        y: isLight ? 0.5 : 0
                    )
            )
        } else {
            glassEffect(.regular.interactive(), in: Circle())
        }
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
