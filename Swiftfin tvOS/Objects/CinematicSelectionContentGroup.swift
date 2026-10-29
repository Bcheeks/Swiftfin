//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import JellyfinAPI
import SwiftUI

struct CinematicSelectionContentGroup: ContentGroup {

    let id = "cinematic-selection"
    let viewModel: CinematicSelectionContentGroupViewModel

    var _shouldBeResolved: Bool {
        viewModel.hasContent
    }

    init(
        suggestedLibrary: SuggestedItemsLibrary,
        resumeLibrary: ResumeItemsLibrary,
        recentlyAddedLibrary: RecentlyAddedLibrary
    ) {
        self.viewModel = CinematicSelectionContentGroupViewModel(
            suggestedLibrary: suggestedLibrary,
            resumeLibrary: resumeLibrary,
            recentlyAddedLibrary: recentlyAddedLibrary
        )
    }

    func body(with viewModel: CinematicSelectionContentGroupViewModel) -> some View {
        SelectionView(viewModel: viewModel)
    }

    private struct SelectionView: View {

        @Environment(\.frameForParentView)
        private var frameForParentView

        @ObservedObject
        var viewModel: CinematicSelectionContentGroupViewModel

        @Router
        private var router

        private var parentFrame: CGRect {
            frameForParentView[.scrollView, default: .zero].frame
        }

        private func itemSelectorImageSource(for item: BaseItemDto) -> ImageSource? {
            if item.type == .episode {
                item.imageSource(
                    .logo,
                    itemID: item.parentLogoItemID,
                    tag: item.parentLogoImageTag,
                    environment: ImageSourceOptions(
                        maxWidth: CinematicSelectionLayout.logoMaxWidth,
                        maxHeight: CinematicSelectionLayout.logoMaxHeight
                    )
                )
            } else {
                item.imageSource(
                    .logo,
                    itemID: item.id,
                    environment: ImageSourceOptions(
                        maxWidth: CinematicSelectionLayout.logoMaxWidth,
                        maxHeight: CinematicSelectionLayout.logoMaxHeight
                    )
                )
            }
        }

        var body: some View {
            let items = viewModel.heroItems

            CinematicItemSelector(
                items: items
            ) { item in
                router.route(to: .item(item: item.snapshot))
            } topContent: { item in
                ImageView(itemSelectorImageSource(for: item.snapshot))
                    .placeholder { _ in
                        EmptyView()
                    }
                    .failure {
                        Text(item.displayTitle)
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                    }
                    .edgePadding(.leading)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: CinematicSelectionLayout.logoMaxHeight, alignment: .bottomLeading)
                    .frame(maxWidth: CinematicSelectionLayout.logoMaxWidth)
            }
            .preference(
                key: ContentGroupCustomizationKey.self,
                value: .ignoreSafeAreaTop
            )
        }
    }
}

struct CinematicRecentlyAddedContentGroup: ContentGroup {

    let id = "cinematic-recently-added"
    let viewModel: CinematicSelectionContentGroupViewModel

    /// Shown unless the hero is already showing recently added items
    var _shouldBeResolved: Bool {
        (viewModel.hasSuggestions || viewModel.hasResumeItems) && viewModel.recentlyAddedViewModel.elements.isNotEmpty
    }

    func body(with viewModel: CinematicSelectionContentGroupViewModel) -> some View {
        PosterHStackLibrarySection(
            viewModel: viewModel.recentlyAddedViewModel,
            group: viewModel.recentlyAddedGroup
        )
    }
}

final class CinematicSelectionContentGroupViewModel: ViewModel, WithRefresh {

    struct Background: WithRefresh {

        let viewModel: CinematicSelectionContentGroupViewModel

        func refresh() {
            Task { await refresh() }
        }

        // Suggestions are intentionally not refreshed in the background
        // so the hero doesn't reshuffle while browsing.
        func refresh() async {
            async let resume: Void = viewModel.resumeViewModel.background.refresh()
            async let recentlyAdded: Void = viewModel.recentlyAddedViewModel.background.refresh()
            _ = await (resume, recentlyAdded)
        }
    }

    let recentlyAddedGroup: PosterGroup<RecentlyAddedLibrary>
    let resumeViewModel: PagingLibraryViewModel<ResumeItemsLibrary>
    let suggestedViewModel: PagingLibraryViewModel<SuggestedItemsLibrary>

    var recentlyAddedViewModel: PagingLibraryViewModel<RecentlyAddedLibrary> {
        recentlyAddedGroup.viewModel
    }

    var background: Background {
        get { Background(viewModel: self) }
        set {}
    }

    var hasResumeItems: Bool {
        resumeViewModel.elements.isNotEmpty
    }

    var hasSuggestions: Bool {
        suggestedViewModel.elements.isNotEmpty
    }

    var hasContent: Bool {
        hasSuggestions || hasResumeItems || recentlyAddedViewModel.elements.isNotEmpty
    }

    /// Suggestions first, falling back to resume, then recently added
    var heroItems: [ItemEntry] {
        if hasSuggestions {
            suggestedViewModel.elements.elements
        } else if hasResumeItems {
            resumeViewModel.elements.elements
        } else {
            recentlyAddedViewModel.elements.elements
        }
    }

    init(
        suggestedLibrary: SuggestedItemsLibrary,
        resumeLibrary: ResumeItemsLibrary,
        recentlyAddedLibrary: RecentlyAddedLibrary
    ) {
        self.suggestedViewModel = PagingLibraryViewModel(library: suggestedLibrary, pageSize: 10)
        self.resumeViewModel = PagingLibraryViewModel(library: resumeLibrary, pageSize: 20)
        self.recentlyAddedGroup = PosterGroup(library: recentlyAddedLibrary)

        super.init()

        resumeViewModel.objectWillChange
            .merge(with: recentlyAddedViewModel.objectWillChange)
            .merge(with: suggestedViewModel.objectWillChange)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        Task {
            await refresh()
        }
    }

    func refresh() async {
        async let suggested: Void = suggestedViewModel.refresh()
        async let resume: Void = resumeViewModel.refresh()
        async let recentlyAdded: Void = recentlyAddedViewModel.refresh()

        _ = await (suggested, resume, recentlyAdded)
    }
}

private enum CinematicSelectionLayout {

    static let logoMaxHeight: CGFloat = 100
    static let logoMaxWidth: CGFloat = 450
}
