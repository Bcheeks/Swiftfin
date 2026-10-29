//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

struct EPGSupplement: MediaPlayerSupplement {

    let displayTitle: String = L10n.guide
    let id: String = "EPG"
    let presentationStyle: MediaPlayerSupplementPresentationStyle = .expanded

    /// Holds the guide data for the playback session (see `LiveTVChannelController.guideViewModel`).
    let controller: LiveTVChannelController

    var videoPlayerBody: some PlatformView {
        GuideOverlay(controller: controller)
    }
}

extension EPGSupplement {

    private struct GuideOverlay: PlatformView {

        @Environment(\.safeAreaInsets)
        private var safeAreaInsets

        @Environment(VideoPlayer.ViewState.self)
        private var viewState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        @ObservedObject
        private var viewModel: EPGViewModel

        private let controller: LiveTVChannelController

        // Programs only change at the edges of the time window, which the view model
        // already rolls forward on its own; a periodic full reload just shows a spinner.
        private let refreshInterval: TimeInterval = 15 * 60

        init(controller: LiveTVChannelController) {
            self.controller = controller
            self.viewModel = controller.guideViewModel
        }

        @ViewBuilder
        private var content: some View {
            EPGLoadableView(viewModel: viewModel) {
                EPGContentView(
                    viewModel: viewModel,
                    selectedChannelID: manager.item.id,
                    action: select
                )
            }
            .if(UIDevice.isPhone) { view in
                view
                    .padding(.leading, safeAreaInsets.leading)
            }
            .onFirstAppear {
                // Usually already preloaded by `LiveTVChannelController`
                guard viewModel.state == .initial else { return }

                viewModel.refresh(startDate: nil)
            }
            .onChange(of: viewModel.state) { _, state in
                guard state == .content else { return }

                controller.guideLastRefresh = .now
            }
            .onChange(of: viewState.selectedSupplementID) { _, id in
                guard id == "EPG",
                      viewModel.state != .initial,
                      viewModel.state != .refreshing,
                      !viewModel.background.is(.gettingNextPage)
                else { return }

                let hasRecentGuide = Date.now.timeIntervalSince(controller.guideLastRefresh) < refreshInterval
                let hasError = viewModel.state == .error

                guard hasError || !hasRecentGuide else { return }

                Task {
                    await viewModel.refresh(startDate: nil)
                }
            }
            .refreshable {
                await viewModel.refresh(startDate: nil)
            }
            .focusSection()
        }

        var iOSView: some View {
            content
        }

        var tvOSView: some View {
            content
                .focusSection()
        }

        private func select(_ item: BaseItemDto) {
            let playbackItem = item.channelID
                .flatMap { channelID in
                    viewModel.channels.first { $0.itemID == channelID }?.value
                } ?? item

            if playbackItem.id == manager.item.id {
                viewState.selectedSupplementID = nil
                return
            }

            guard let provider = playbackItem.getPlaybackItemProvider(userSession: viewModel.userSession) else {
                return
            }

            viewState.selectedSupplementID = nil
            manager.playNewItem(provider: provider)
        }
    }
}
