//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import JellyfinAPI
import SwiftUI

struct EPGCollectionView: UIViewRepresentable {

    @ObservedObject
    var viewModel: EPGViewModel

    let proxy: EPGScrollProxy
    /// The channel whose now-airing program receives initial focus on tvOS.
    let selectedChannelID: String?
    let bottomInset: CGFloat
    let onReachedBottom: () -> Void
    let onSelect: (BaseItemDto) -> Void
    let onSelectGroup: (ProgramBlock) -> Void
    /// Whether the grid moves focus into itself when it appears on tvOS.
    /// Disabled where focus may still be in the tab sidebar.
    var autoFocusesOnAppear: Bool = true

    private let layout = EPGLayout()

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = EPGGridCollectionView(frame: .zero, collectionViewLayout: context.coordinator.gridLayout)
        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.selfSizingInvalidation = .disabled
        collectionView.delegate = context.coordinator

        #if os(tvOS)
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.onPlayPause = { [weak coordinator = context.coordinator] in
            coordinator?.jumpToNow()
        }
        collectionView.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleInitialFocus()
        }
        #endif

        context.coordinator.representable = self
        context.coordinator.configure(collectionView)

        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.representable = self

        if collectionView.contentInset.bottom != bottomInset {
            collectionView.contentInset.bottom = bottomInset
        }

        context.coordinator.update(collectionView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

extension EPGCollectionView {

    final class Coordinator: NSObject, UICollectionViewDelegate {

        private struct ItemID: Hashable {

            let channelID: String
            let blockID: ProgramBlock.ID
            let duplicateIndex: Int
        }

        private struct RenderItem: Equatable {

            let id: ItemID
            let block: ProgramBlock
            let frame: CGRect

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.id == rhs.id && lhs.frame == rhs.frame
            }
        }

        private struct RenderSection: Equatable {

            let id: String
            let items: [RenderItem]
        }

        private struct RenderContentSignature: Equatable {

            let channelIDs: [String]
            let programsRevision: Int
            let startDate: Date
            let layout: EPGLayout
        }

        private struct RenderState: Equatable {

            let sections: [RenderSection]
            let contentWidth: CGFloat
            let nowOffset: CGFloat?
            let now: Date
            let programsRevision: Int
            let rowHeight: CGFloat
        }

        var representable: EPGCollectionView?

        let gridLayout = EPGGridLayout()

        private weak var collectionView: UICollectionView?

        private var accentColor = Defaults[.accentColor]
        private var cancellables: Set<AnyCancellable> = []
        private var dataSource: UICollectionViewDiffableDataSource<String, ItemID>?
        private var didRequestNextPage = false
        private var lastPaginationVerticalOffset: CGFloat?
        private var renderContentSignature: RenderContentSignature?
        private var renderItems: [ItemID: RenderItem] = [:]
        private var renderState: RenderState?
        private let scrollState = EPGScrollState()
        private var wasLoadingNextPage = false

        #if os(tvOS)
        /// Horizontal content position (time) that vertical focus moves try to keep.
        private var focusAnchor: CGFloat?
        private var lastFocusedIndexPath: IndexPath?
        private var pendingFocusIndexPath: IndexPath?
        private var redirectFocusIndexPath: IndexPath?
        /// Set when a redirect failed to move focus, so the next move uses UIKit's default
        /// instead of being cancelled again. Prevents focus from getting stuck.
        private var bypassNextRedirect = false
        private var hasReceivedFocus = false
        private var didPerformInitialFocus = false
        private var isInitialFocusScheduled = false
        #endif

        func configure(_ collectionView: UICollectionView) {
            self.collectionView = collectionView
            lastPaginationVerticalOffset = collectionView.contentOffset.y

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, ItemID> { [weak self] cell, _, itemID in
                cell.configurationUpdateHandler = { [weak self] cell, state in
                    self?.configure(
                        cell,
                        for: itemID,
                        isFocused: state.isFocused
                    )
                }

                self?.configure(
                    cell,
                    for: itemID,
                    isFocused: cell.isFocused
                )
            }

            scrollState.update(visibleLeadingOffset: collectionView.contentOffset.x)

            dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
            }

            Defaults.publisher(.accentColor)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }

                    self.accentColor = Defaults[.accentColor]
                    self.gridLayout.nowColor = UIColor(self.accentColor)
                    self.gridLayout.invalidateLayout()
                    self.refreshVisibleCells()
                }
                .store(in: &cancellables)
        }

        func update(_ collectionView: UICollectionView) {
            guard let representable else { return }

            let viewModel = representable.viewModel
            let layout = representable.layout
            let contentSignature = RenderContentSignature(
                channelIDs: viewModel.channels.map(\.itemID),
                programsRevision: viewModel.programsRevision,
                startDate: viewModel.startDate,
                layout: layout
            )
            let sections: [RenderSection]

            if contentSignature != renderContentSignature {
                if let renderContentSignature,
                   renderContentSignature.startDate != contentSignature.startDate
                {
                    representable.proxy.reset()

                    #if os(tvOS)
                    focusAnchor = nil
                    lastFocusedIndexPath = nil
                    #endif
                }

                sections = makeSections(viewModel: viewModel, layout: layout)
                renderItems = sections.reduce(into: [:]) { lookup, section in
                    for item in section.items {
                        lookup[item.id] = item
                    }
                }
                renderContentSignature = contentSignature
            } else {
                sections = renderState?.sections ?? []
            }

            let nowOffset = layout.width(from: viewModel.startDate, to: viewModel.now)
            let nextRenderState = RenderState(
                sections: sections,
                contentWidth: max(1, layout.width(from: viewModel.startDate, to: viewModel.endDate)),
                nowOffset: viewModel.now >= viewModel.startDate ? nowOffset : nil,
                now: viewModel.now,
                programsRevision: viewModel.programsRevision,
                rowHeight: layout.rowHeight
            )

            let sectionsDidChange = renderState?.sections != nextRenderState.sections
            let layoutDidChange = sectionsDidChange ||
                renderState?.contentWidth != nextRenderState.contentWidth ||
                renderState?.nowOffset != nextRenderState.nowOffset ||
                renderState?.rowHeight != nextRenderState.rowHeight
            let programsDidChange = renderState?.programsRevision != nextRenderState.programsRevision
            let previousNow = renderState?.now

            gridLayout.rowHeight = nextRenderState.rowHeight
            gridLayout.contentWidth = nextRenderState.contentWidth
            gridLayout.nowOffset = nextRenderState.nowOffset
            gridLayout.nowColor = UIColor(accentColor)

            if sectionsDidChange {
                gridLayout.sectionFrames = nextRenderState.sections.map { section in
                    section.items.map(\.frame)
                }
                didRequestNextPage = false
                applySnapshot(nextRenderState, to: collectionView)
            } else if layoutDidChange {
                UIView.performWithoutAnimation {
                    gridLayout.invalidateLayout()
                }
            }

            renderState = nextRenderState

            if programsDidChange {
                refreshVisibleCells()
            } else if let previousNow, previousNow != nextRenderState.now {
                // The now line is a layout decoration; only cells whose airing state flipped need new content.
                let now = nextRenderState.now
                refreshVisibleCells { block in
                    block.isAiring(at: previousNow) != block.isAiring(at: now)
                }
            }

            if wasLoadingNextPage, !viewModel.background.is(.gettingNextPage) {
                didRequestNextPage = false
            }
            wasLoadingNextPage = viewModel.background.is(.gettingNextPage)

            representable.proxy.registerContent(collectionView, centeringOn: gridLayout.nowOffset)
            representable.proxy.registerVertical(collectionView)

            #if os(tvOS)
            if nextRenderState.sections.contains(where: \.items.isNotEmpty) {
                scheduleInitialFocus()
            }
            #endif
        }

        private func makeSections(
            viewModel: EPGViewModel,
            layout: EPGLayout
        ) -> [RenderSection] {
            viewModel.channels.enumerated().compactMap { section, channel -> RenderSection? in
                let channelID = channel.itemID

                var occurrences: [ProgramBlock.ID: Int] = [:]
                let items = (viewModel.programs[channelID] ?? []).map { block in
                    let duplicateIndex = occurrences[block.id, default: 0]
                    occurrences[block.id] = duplicateIndex + 1
                    let id = ItemID(
                        channelID: channelID,
                        blockID: block.id,
                        duplicateIndex: duplicateIndex
                    )
                    let leadingOffset = layout.width(from: viewModel.startDate, to: block.start)

                    return RenderItem(
                        id: id,
                        block: block,
                        frame: CGRect(
                            x: leadingOffset,
                            y: CGFloat(section) * layout.rowHeight,
                            width: layout.width(from: block.start, to: block.end),
                            height: layout.rowHeight
                        )
                    )
                }

                return RenderSection(id: channelID, items: items)
            }
        }

        private func applySnapshot(_ renderState: RenderState, to collectionView: UICollectionView) {
            var snapshot = NSDiffableDataSourceSnapshot<String, ItemID>()
            snapshot.appendSections(renderState.sections.map(\.id))

            for section in renderState.sections {
                snapshot.appendItems(section.items.map(\.id), toSection: section.id)
            }

            UIView.performWithoutAnimation {
                dataSource?.apply(snapshot, animatingDifferences: false)
                gridLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
            }
        }

        private func configure(
            _ cell: UICollectionViewCell,
            for itemID: ItemID,
            isFocused: Bool
        ) {
            guard let representable,
                  let renderItem = renderItems[itemID]
            else { return }

            let block = renderItem.block

            let action = { [weak self] in
                guard let self else { return }

                select(itemID)
            }

            cell.contentConfiguration = UIHostingConfiguration {
                EPGProgramCell(
                    scrollState: scrollState,
                    block: block,
                    leadingOffset: renderItem.frame.minX,
                    width: renderItem.frame.width,
                    isCurrent: block.isAiring(at: representable.viewModel.now),
                    isFocused: isFocused,
                    accentColor: accentColor,
                    action: action
                )
                .ignoresSafeArea()
            }
            .margins(.all, 0)

            cell.backgroundConfiguration = .clear()
            cell.clipsToBounds = true

            #if os(iOS)
            cell.focusEffect = nil
            #endif
        }

        private func select(_ itemID: ItemID) {
            guard let representable,
                  let block = renderItems[itemID]?.block
            else { return }

            if block.isGroup {
                representable.onSelectGroup(block)
            } else if let program = block.programs.first {
                representable.onSelect(program)
            }
        }

        private func refreshVisibleCells(
            where shouldRefresh: (ProgramBlock) -> Bool = { _ in true }
        ) {
            guard let collectionView, let dataSource else { return }

            UIView.performWithoutAnimation {
                for cell in collectionView.visibleCells {
                    guard let indexPath = collectionView.indexPath(for: cell),
                          let itemID = dataSource.itemIdentifier(for: indexPath),
                          let block = renderItems[itemID]?.block,
                          shouldRefresh(block)
                    else { continue }

                    configure(
                        cell,
                        for: itemID,
                        isFocused: cell.isFocused
                    )
                }
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath) else { return }

            select(itemID)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let representable else { return }

            scrollState.update(visibleLeadingOffset: scrollView.contentOffset.x)

            let verticalOffset = scrollView.contentOffset.y
            let didScrollVertically = lastPaginationVerticalOffset.map {
                abs($0 - verticalOffset) > 0.5
            } ?? true
            lastPaginationVerticalOffset = verticalOffset

            guard didScrollVertically else { return }

            let remaining = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height

            guard remaining < 300 else {
                didRequestNextPage = false
                return
            }
            guard !didRequestNextPage,
                  !representable.viewModel.background.is(.gettingNextPage)
            else { return }

            didRequestNextPage = true
            representable.onReachedBottom()
        }

        // MARK: - tvOS Focus

        #if os(tvOS)
        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            if let pendingFocusIndexPath {
                return pendingFocusIndexPath
            }

            // Until the grid has been focused once, entering it lands on the now-airing program.
            return hasReceivedFocus ? nil : initialFocusIndexPath()
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext
        ) -> Bool {
            let heading = context.focusHeading

            // Hold directional moves while a programmatic redirect is in flight.
            if redirectFocusIndexPath != nil || pendingFocusIndexPath != nil {
                return heading.isEmpty
            }

            guard !heading.isEmpty,
                  let nextIndexPath = context.nextFocusedIndexPath
            else { return true }

            if bypassNextRedirect {
                bypassNextRedirect = false
                return true
            }

            let anchor: CGFloat

            if let previousIndexPath = context.previouslyFocusedIndexPath {
                // Moving between rows: keep the time position instead of the geometric nearest cell.
                guard heading.contains(.up) || heading.contains(.down),
                      previousIndexPath.section != nextIndexPath.section,
                      let focusAnchor
                else { return true }

                anchor = focusAnchor
            } else {
                // Entering the grid from the channel column or date bar.
                guard let target = focusAnchor ?? renderState?.nowOffset else { return true }

                anchor = target
            }

            // Only redirect to a cell that's actually on screen; focus can't move to one that isn't.
            guard let targetIndexPath = indexPath(inSection: nextIndexPath.section, at: anchor),
                  targetIndexPath != nextIndexPath,
                  let targetCell = collectionView.cellForItem(at: targetIndexPath),
                  isMostlyVisible(targetCell, in: collectionView)
            else { return true }

            redirectFocusIndexPath = targetIndexPath

            Task { @MainActor [weak self, weak collectionView] in
                guard let self else { return }

                let target = self.redirectFocusIndexPath
                self.redirectFocusIndexPath = nil

                guard let collectionView, let target else { return }

                self.requestFocus(target, in: collectionView)

                // If focus didn't land on the target, let the next press move normally.
                if !self.isFocused(at: target, in: collectionView) {
                    self.bypassNextRedirect = true
                }
            }

            return false
        }

        private func isMostlyVisible(_ cell: UICollectionViewCell, in collectionView: UICollectionView) -> Bool {
            let visible = collectionView.bounds.intersection(cell.frame)
            guard !visible.isNull else { return false }

            return visible.width >= min(cell.frame.width, 40) && visible.height >= cell.frame.height * 0.5
        }

        private func isFocused(at indexPath: IndexPath, in collectionView: UICollectionView) -> Bool {
            guard let cell = collectionView.cellForItem(at: indexPath),
                  let focusedView = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView
            else { return false }

            return focusedView == cell || focusedView.isDescendant(of: cell)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            guard let nextIndexPath = context.nextFocusedIndexPath,
                  let frame = renderFrame(at: nextIndexPath)
            else { return }

            hasReceivedFocus = true
            lastFocusedIndexPath = nextIndexPath

            if let focusAnchor, frame.minX <= focusAnchor, focusAnchor < frame.maxX {
                return
            }

            focusAnchor = defaultFocusAnchor(for: frame)
        }

        /// Scrolls back to the current time and focuses the now-airing program in the focused row.
        func jumpToNow() {
            guard let collectionView,
                  let representable,
                  let renderState
            else { return }

            let target = renderState.nowOffset ?? 0
            let section = lastFocusedIndexPath?.section ?? initialFocusIndexPath()?.section

            representable.proxy.scrollTo(centering: target, animated: false)
            focusAnchor = target

            guard let section,
                  let focusIndexPath = indexPath(inSection: section, at: target)
            else { return }

            collectionView.layoutIfNeeded()
            requestFocus(focusIndexPath, in: collectionView)
        }

        /// Moves focus from the default SwiftUI target (the date bar or channel column)
        /// to the now-airing program. Retries briefly because SwiftUI may settle its own
        /// initial focus after the grid has content.
        func scheduleInitialFocus() {
            guard !didPerformInitialFocus, !isInitialFocusScheduled else { return }

            isInitialFocusScheduled = true

            Task { @MainActor [weak self] in
                var didAttempt = false

                for delay in [100, 400, 800] {
                    try? await Task.sleep(for: .milliseconds(delay))

                    guard let self else { return }

                    if self.performInitialFocusIfNeeded() {
                        didAttempt = true
                    }
                }

                guard let self else { return }

                self.isInitialFocusScheduled = false

                if didAttempt {
                    self.didPerformInitialFocus = true
                }
            }
        }

        /// Returns whether there was a target to focus.
        private func performInitialFocusIfNeeded() -> Bool {
            guard !didPerformInitialFocus,
                  representable?.autoFocusesOnAppear != false,
                  let collectionView,
                  collectionView.window != nil,
                  let target = initialFocusIndexPath(),
                  let frame = renderFrame(at: target)
            else { return false }
            guard !isFocused(within: collectionView) else { return true }

            focusAnchor = defaultFocusAnchor(for: frame)
            scrollToRowIfNeeded(target.section, in: collectionView)
            collectionView.layoutIfNeeded()
            requestFocus(target, in: collectionView)

            return true
        }

        private func requestFocus(_ indexPath: IndexPath, in collectionView: UICollectionView) {
            pendingFocusIndexPath = indexPath
            defer { pendingFocusIndexPath = nil }

            if let cell = collectionView.cellForItem(at: indexPath),
               let focusSystem = UIFocusSystem.focusSystem(for: collectionView)
            {
                focusSystem.requestFocusUpdate(to: cell)
                focusSystem.updateFocusIfNeeded()
            } else {
                collectionView.setNeedsFocusUpdate()
                collectionView.updateFocusIfNeeded()
            }
        }

        private func isFocused(within collectionView: UICollectionView) -> Bool {
            (UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView)?.isDescendant(of: collectionView) == true
        }

        private func initialFocusIndexPath() -> IndexPath? {
            guard let sections = renderState?.sections else { return nil }

            let selectedSection = representable?.selectedChannelID.flatMap { channelID in
                sections.firstIndex { $0.id == channelID && $0.items.isNotEmpty }
            }

            guard let section = selectedSection ?? sections.firstIndex(where: { $0.items.isNotEmpty }) else { return nil }

            return indexPath(inSection: section, at: renderState?.nowOffset ?? 0)
        }

        private func renderFrame(at indexPath: IndexPath) -> CGRect? {
            renderState?.sections[safe: indexPath.section]?.items[safe: indexPath.item]?.frame
        }

        /// Airing programs anchor at the current time, others at their start.
        private func defaultFocusAnchor(for frame: CGRect) -> CGFloat {
            if let nowOffset = renderState?.nowOffset, frame.minX <= nowOffset, nowOffset < frame.maxX {
                return nowOffset
            }

            return frame.minX
        }

        /// The item in `section` that contains `x`, or the nearest one when `x` falls in a gap.
        private func indexPath(inSection section: Int, at x: CGFloat) -> IndexPath? {
            guard let items = renderState?.sections[safe: section]?.items, items.isNotEmpty else { return nil }

            if let item = items.firstIndex(where: { $0.frame.minX <= x && x < $0.frame.maxX }) {
                return IndexPath(item: item, section: section)
            }

            let nearest = items.indices.min { lhs, rhs in
                distance(from: items[lhs].frame, to: x) < distance(from: items[rhs].frame, to: x)
            }

            return nearest.map { IndexPath(item: $0, section: section) }
        }

        private func distance(from frame: CGRect, to x: CGFloat) -> CGFloat {
            x < frame.minX ? frame.minX - x : max(0, x - frame.maxX)
        }

        private func scrollToRowIfNeeded(_ section: Int, in collectionView: UICollectionView) {
            let rowHeight = gridLayout.rowHeight

            guard rowHeight > 0 else { return }

            let rowMinY = CGFloat(section) * rowHeight
            let visibleMinY = collectionView.contentOffset.y
            let visibleMaxY = visibleMinY + collectionView.bounds.height - collectionView.contentInset.bottom

            guard rowMinY < visibleMinY || rowMinY + rowHeight > visibleMaxY else { return }

            let maximumOffset = max(
                0,
                collectionView.contentSize.height + collectionView.contentInset.bottom - collectionView.bounds.height
            )

            collectionView.setContentOffset(
                CGPoint(
                    x: collectionView.contentOffset.x,
                    y: clamp(rowMinY - rowHeight, min: 0, max: maximumOffset)
                ),
                animated: false
            )
        }
        #endif
    }
}

/// Handles tvOS remote presses and window changes for the guide grid.
private final class EPGGridCollectionView: UICollectionView {

    #if os(tvOS)
    var onPlayPause: (() -> Void)?
    var onDidMoveToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            onDidMoveToWindow?()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .playPause }

        if remaining.isNotEmpty {
            super.pressesBegan(remaining, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .playPause }

        if remaining.count != presses.count {
            onPlayPause?()
        }

        if remaining.isNotEmpty {
            super.pressesEnded(remaining, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .playPause }

        if remaining.isNotEmpty {
            super.pressesCancelled(remaining, with: event)
        }
    }
    #endif
}
