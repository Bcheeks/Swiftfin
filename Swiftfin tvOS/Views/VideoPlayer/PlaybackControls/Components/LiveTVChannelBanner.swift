//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension VideoPlayer.PlaybackControls {

    /// Transient now/next banner shown when a live TV channel is tuned
    /// while the playback overlay is dismissed.
    struct LiveTVChannelBanner: View {

        @Environment(ViewState.self)
        private var viewState

        @ObservedObject
        var controller: LiveTVChannelController

        private let displayDuration: Duration = .seconds(4)

        private var isVisible: Bool {
            controller.banner != nil &&
                viewState.presentation == .hidden &&
                !viewState.isScrubbing
        }

        /// Restart the dismiss countdown when the banner changes or becomes visible.
        private var dismissTaskID: String {
            "\(controller.banner?.token ?? -1)-\(isVisible)"
        }

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                if isVisible, let banner = controller.banner {
                    BannerContent(banner: banner)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .animation(.easeInOut(duration: 0.25), value: isVisible)
            .allowsHitTesting(false)
            .onChange(of: viewState.presentation) { oldValue, newValue in
                // A banner already seen is not shown again after the overlay is dismissed
                guard oldValue == .hidden, newValue != .hidden, let token = controller.banner?.token else { return }

                controller.dismissBanner(token: token)
            }
            .task(id: dismissTaskID) {
                guard isVisible, let token = controller.banner?.token else { return }

                try? await Task.sleep(for: displayDuration)

                guard !Task.isCancelled else { return }

                controller.dismissBanner(token: token)
            }
        }
    }
}

extension VideoPlayer.PlaybackControls.LiveTVChannelBanner {

    private struct BannerContent: View {

        let banner: LiveTVChannelController.Banner

        private var channel: BaseItemDto {
            banner.channel
        }

        private var hasPrimaryImage: Bool {
            channel.imageTags?[ImageType.primary.rawValue] != nil
        }

        private func timeRange(for program: BaseItemDto) -> String? {
            guard let startDate = program.startDate, let endDate = program.endDate else { return nil }

            let start = startDate.formatted(date: .omitted, time: .shortened)
            let end = endDate.formatted(date: .omitted, time: .shortened)

            return "\(start) \(String.enDash) \(end)"
        }

        private func nextLabel(for program: BaseItemDto) -> String {
            if let startDate = program.startDate {
                let start = startDate.formatted(date: .omitted, time: .shortened)

                // swiftlint:disable:next hard_coded_display_string
                return "\(L10n.next): \(start) \(String.bullet) \(program.displayTitle)"
            }

            // swiftlint:disable:next hard_coded_display_string
            return "\(L10n.next): \(program.displayTitle)"
        }

        var body: some View {
            HStack(alignment: .center, spacing: 30) {
                if hasPrimaryImage {
                    PosterImage(
                        item: channel,
                        type: .square,
                        contentMode: .fit
                    )
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        if let channelNumber = channel.channelNumber, channelNumber.isNotEmpty {
                            Text(channelNumber)
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }

                        Text(channel.displayTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)

                    if let currentProgram = banner.currentProgram {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(currentProgram.displayTitle)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if let timeRange = timeRange(for: currentProgram) {
                                Text(timeRange)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }

                    if let nextProgram = banner.nextProgram {
                        Text(nextLabel(for: nextProgram))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .background {
                RoundedRectangle(cornerRadius: 32)
                    .fill(Material.thin)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32))
            .frame(maxWidth: 1200, alignment: .leading)
        }
    }
}
