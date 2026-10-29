//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CollectionHStack
import Nuke
import SwiftUI

struct PosterHStack<
    Data: Collection
>: View where Data.Element: Poster, Data.Index == Int {

    let elements: Data
    let displayType: PosterDisplayType
    let size: PosterDisplayType.Size
    let action: (Data.Element, Namespace.ID) -> Void

    private var layout: CollectionHStackLayout {
        #if os(tvOS)
        .grid(
            columns: displayType == .landscape ? 5 : 7,
            rows: 1,
            columnTrailingInset: 0
        )
        #else
        if UIDevice.isPad {
            let minWidth: CGFloat = {
                switch (displayType, size) {
                case (.landscape, .small):
                    220
                case (.landscape, .medium):
                    300
                case (_, .small):
                    140
//                case (_, .medium):
                default:
                    200
                }
            }()

            return .minimumWidth(
                columnWidth: minWidth,
                rows: 1
            )
        } else {
            let columnCount: CGFloat = {
                switch (displayType, size) {
                case (.landscape, .small):
                    2
                case (.landscape, .medium):
                    1.5
                case (_, .small):
                    3
//                case (_, .medium):
                default:
                    2
                }
            }()

            return .grid(
                columns: columnCount,
                rows: 1,
                columnTrailingInset: 0
            )
        }
        #endif
    }

    var body: some View {
        CollectionHStack(
            uniqueElements: elements,
            layout: layout
        ) { item in
            PosterButton(
                item: item,
                displayType: displayType,
                size: size
            ) { namespace in
                action(item, namespace)
            }
        }
        .clipsToBounds(false)
        .insets(horizontal: EdgeInsets.edgePadding)
        .itemSpacing(EdgeInsets.itemSpacing)
        .scrollBehavior(.continuousLeadingEdge)
        .background {
            PosterImagePrefetchView(
                elements: elements,
                displayType: displayType,
                size: size
            )
        }
        .withViewContext(.isThumb)
    }
}

/// Prefetches the images of posters not yet visible in a row, requesting the
/// same URLs that `PosterImage` would so the pipeline caches can be used.
private struct PosterImagePrefetchView<Data: Collection>: View where Data.Element: Poster {

    @Environment(\.self)
    private var environment

    let elements: Data
    let displayType: PosterDisplayType
    let size: PosterDisplayType.Size

    var body: some View {
        // Resolved during view updates, same as `PosterImage`
        let urls: [URL] = elements.compactMap { (element: Data.Element) -> URL? in
            let sources = element.imageSources(
                for: displayType,
                size: size,
                environment: element.resolveEnvironment(environment)
            )

            return sources.first(where: { $0.url != nil })?.url
        }

        Color.clear
            .accessibilityHidden(true)
            .onAppear {
                ImagePrefetcher.Swiftfin.posters.startPrefetching(with: urls)
            }
            .onChange(of: urls) { _, newURLs in
                ImagePrefetcher.Swiftfin.posters.startPrefetching(with: newURLs)
            }
            .onDisappear {
                ImagePrefetcher.Swiftfin.posters.stopPrefetching(with: urls)
            }
    }
}
