//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

struct EPGView: View {

    @Router
    private var router

    @StateObject
    private var viewModel = EPGViewModel()

    private let autoFocusesOnAppear: Bool

    init(autoFocusesOnAppear: Bool = true) {
        self.autoFocusesOnAppear = autoFocusesOnAppear
    }

    @ViewBuilder
    private var contentView: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            EPGDateBar(viewModel: viewModel)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            #endif

            EPGContentView(
                viewModel: viewModel,
                autoFocusesOnAppear: autoFocusesOnAppear,
                action: select
            )
        }
    }

    /// Channels and currently airing programs tune immediately.
    /// Programs that haven't started yet open their details.
    private func select(_ item: BaseItemDto) {
        guard item.isTunable else {
            router.route(to: .item(item: item))
            return
        }

        let channel = item.channelID
            .flatMap { channelID in
                viewModel.channels.first { $0.itemID == channelID }?.value
            } ?? item

        guard let provider = channel.getPlaybackItemProvider(userSession: viewModel.userSession) else {
            router.route(to: .item(item: item))
            return
        }

        router.route(to: .videoPlayer(provider: provider))
    }

    var body: some View {
        EPGLoadableView(viewModel: viewModel) {
            contentView
        }
        .onFirstAppear {
            viewModel.refresh(startDate: nil)
        }
        .refreshable {
            await viewModel.refresh(startDate: nil)
        }
        .onSceneWillEnterForeground {
            Task {
                await viewModel.refresh(startDate: nil)
            }
        }
        #if os(iOS)
        .topBarTrailing {
            EPGDateMenu(viewModel: viewModel)
        }
        .navigationTitle(L10n.guide)
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        #else
        .ignoresSafeArea(edges: [.horizontal])
        #endif
    }
}
