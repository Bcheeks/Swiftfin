//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import Foundation
import JellyfinAPI

struct DefaultContentGroupProvider: ContentGroupProvider {

    private enum LiveTVShortcut: Displayable, SystemImageable {
        case guide
        case channels

        var displayTitle: String {
            switch self {
            case .guide:
                L10n.guide
            case .channels:
                L10n.channels
            }
        }

        var systemImage: String {
            switch self {
            case .guide:
                "tablecells"
            case .channels:
                "play.square.stack"
            }
        }
    }

    @Injected(\.currentUserSession)
    var userSession: UserSession?

    let displayTitle: String = L10n.home
    let id: String = "default-content-group-provider"

    func makeGroups(environment: Empty) async throws -> [any ContentGroup] {
        guard let userSession else { return [] }

        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let userViewsPath = Paths.getUserViews(parameters: parameters)
        let userViews = try await userSession.send(userViewsPath)
        let excludedLibraryIDs = userSession.user.data.configuration?.latestItemsExcludes ?? []

        let resolvedUserViews = (userViews.value.items ?? [])
            .subtracting(excludedLibraryIDs, using: \.id)
            .intersecting(
                [
                    .homevideos,
                    .movies,
                    .musicvideos,
                    .tvshows,
                ],
                using: \.collectionType
            )

        let hasLiveTV = userSession.user.data.policy?.enableLiveTvAccess == true

        return _makeGroups(userViews: resolvedUserViews, hasLiveTV: hasLiveTV)
    }

    @ContentGroupBuilder
    private func _makeGroups(userViews: [BaseItemDto], hasLiveTV: Bool) -> [any ContentGroup] {

        #if os(tvOS)
        // Hero: random unwatched suggestions, with Continue Watching as its own row
        let cinematicSelectionContentGroup = CinematicSelectionContentGroup(
            suggestedLibrary: SuggestedItemsLibrary(),
            resumeLibrary: ResumeItemsLibrary(mediaTypes: [.video]),
            recentlyAddedLibrary: RecentlyAddedLibrary()
        )

        cinematicSelectionContentGroup
        #endif

        PosterGroup(
            id: "home-resume",
            library: ResumeItemsLibrary(mediaTypes: [.video]),
            posterDisplayType: .landscape,
            posterSize: .medium,
            _viewContext: .isInResume
        )

        PosterGroup(
            id: "home-next-up",
            library: NextUpLibrary()
        )

        if Defaults[.Customization.Home.showRecentlyAdded] {
            #if os(tvOS)
            CinematicRecentlyAddedContentGroup(
                viewModel: cinematicSelectionContentGroup.viewModel
            )
            #else
            PosterGroup(
                id: "home-recently-added",
                library: ItemLibrary(
                    parent: BaseItemDto(name: L10n.recentlyAdded.localizedCapitalized),
                    filters: .init(
                        itemTypes: [.movie, .series],
                        sortBy: [.dateCreated],
                        sortOrder: [.descending]
                    )
                )
            )
            #endif
        }

        if Defaults[.Customization.Home.showRecentlyPlayed] {
            PosterGroup(
                id: "home-recently-played",
                library: ItemLibrary(
                    parent: BaseItemDto(name: L10n.recentlyPlayed.localizedCapitalized),
                    filters: .init(
                        itemTypes: [.movie, .series],
                        sortBy: [.datePlayed],
                        sortOrder: [.descending],
                        traits: [.isPlayed]
                    )
                )
            )
        }

        PillGroup(
            displayTitle: L10n.liveTV,
            id: "home-live-tv",
            elements: hasLiveTV ? [LiveTVShortcut.guide, .channels] : []
        ) { router, shortcut in
            switch shortcut {
            case .guide:
                router.route(to: .liveGuide)
            case .channels:
                router.route(
                    to: .library(
                        library: ItemLibrary(
                            parent: BaseItemDto(name: L10n.channels),
                            filters: .init(itemTypes: [.liveTvChannel])
                        )
                    )
                )
            }
        }

        PosterGroup(
            id: "programs-recommended",
            library: RecommendedProgramsLibrary(),
            posterDisplayType: .landscape,
            posterSize: .small
        )

        userViews
            .map { userView in
                PosterGroup(
                    id: "home-latest-\(userView.id ?? UUID().uuidString)",
                    library: LatestInLibrary(library: userView),
                    posterDisplayType: .landscape
                )
            }
    }
}
