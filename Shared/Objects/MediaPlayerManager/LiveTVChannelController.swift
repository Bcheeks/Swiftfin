//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import JellyfinAPI

/// Live TV helpers for a `MediaPlayerManager`: channel up/down in
/// guide order, last channel recall, and the now/next banner state.
@MainActor
final class LiveTVChannelController: ViewModel {

    struct Banner {

        let channel: BaseItemDto
        var currentProgram: BaseItemDto?
        var nextProgram: BaseItemDto?

        /// Changes whenever the banner should be (re)presented.
        var token: Int

        var channelID: String? {
            channel.id
        }
    }

    weak var manager: MediaPlayerManager? {
        didSet {
            playbackItemCancellable = manager?.$playbackItem
                .sink { [weak self] newItem in
                    self?.didReceive(newItem: newItem)
                }
        }
    }

    @Published
    private(set) var banner: Banner?

    /// Fork: the in-player guide's data lives for the whole playback session, so the
    /// Guide tab opens instantly instead of reloading every time the panel is shown.
    let guideViewModel = EPGViewModel()
    var guideLastRefresh: Date = .distantPast
    private var guidePreloadTask: Task<Void, Never>?

    private var playbackItemCancellable: AnyCancellable?

    private var channelsTask: Task<[BaseItemDto], Never>?
    private var programsTask: Task<Void, Never>?
    private var tuneTask: Task<Void, Never>?

    private var currentChannel: BaseItemDto?
    private var previousChannel: BaseItemDto?

    /// Channel index selected by up/down presses that has not been tuned yet.
    private var pendingIndex: Int?
    private var bannerToken = 0

    /// Delay before tuning, so several presses in a row only tune the final channel.
    private let tuneDelay: Duration = .milliseconds(650)

    // MARK: - Playback Item

    private func didReceive(newItem: MediaPlayerItem?) {
        guard let baseItem = newItem?.baseItem,
              baseItem.isLiveStream,
              let channelID = baseItem.id
        else { return }

        // Rebuilds (audio track, bitrate) keep the same channel.
        guard channelID != currentChannel?.id else { return }

        // The guide opens on the last watched channel
        Defaults[.Experimental.lastWatchedLiveTVChannelID] = channelID

        preloadGuideIfNeeded()

        if let currentChannel {
            previousChannel = currentChannel
        }

        // Drop any opened live stream source so a later recall opens a new stream.
        var channel = baseItem
        channel.mediaSources = nil
        currentChannel = channel
        pendingIndex = nil

        showBanner(for: channel)
    }

    // MARK: - Guide Preload

    /// Loads the in-player guide a few seconds after the first channel starts,
    /// so it doesn't compete with the stream starting up.
    private func preloadGuideIfNeeded() {
        guard Defaults[.Experimental.videoPlayerEPG],
              guidePreloadTask == nil,
              guideViewModel.state == .initial
        else { return }

        guidePreloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.guideViewModel.state == .initial else { return }

            await self.guideViewModel.refresh(startDate: nil)

            if self.guideViewModel.state == .content {
                self.guideLastRefresh = .now
            }
        }
    }

    // MARK: - Channel Up / Down

    /// Switch channels relative to the current channel in guide order.
    ///
    /// - Parameter offset: `1` for the next channel, `-1` for the previous channel.
    func switchChannel(by offset: Int) {
        Task {
            await _switchChannel(by: offset)
        }
    }

    private func _switchChannel(by offset: Int) async {
        let channels = await loadChannels()
        guard channels.isNotEmpty else { return }

        let count = channels.count
        let currentID = currentChannel?.id
        let baseIndex = pendingIndex
            ?? channels.firstIndex(where: { $0.id == currentID })
            ?? (offset > 0 ? -1 : 0)
        let newIndex = ((baseIndex + offset) % count + count) % count
        let channel = channels[newIndex]

        pendingIndex = newIndex
        showBanner(for: channel)

        tuneTask?.cancel()
        tuneTask = Task { [weak self, tuneDelay] in
            try? await Task.sleep(for: tuneDelay)
            guard !Task.isCancelled else { return }

            self?.tune(to: channel)
        }
    }

    // MARK: - Last Channel

    var hasPreviousChannel: Bool {
        previousChannel != nil
    }

    /// Tune back to the previously watched channel.
    ///
    /// - Returns: `false` if there is no previous channel.
    @discardableResult
    func recallPreviousChannel() -> Bool {
        guard let previousChannel, let previousID = previousChannel.id else { return false }

        tuneTask?.cancel()
        tuneTask = nil
        pendingIndex = nil

        let channel = cachedChannels.first(where: { $0.id == previousID }) ?? previousChannel

        showBanner(for: channel)
        tune(to: channel)
        return true
    }

    // MARK: - Tune

    private func tune(to channel: BaseItemDto) {
        tuneTask = nil

        guard let manager else { return }
        guard channel.id != currentChannel?.id else {
            pendingIndex = nil
            return
        }
        guard let provider = channel.getPlaybackItemProvider(userSession: userSession) else {
            logger.error("Unable to create playback provider for channel \(channel.id ?? "Unknown")")
            pendingIndex = nil
            return
        }

        manager.playNewItem(provider: provider)
    }

    // MARK: - Channels

    private var cachedChannels: [BaseItemDto] = []

    /// Loads the channel list once, in the same order as the guide.
    private func loadChannels() async -> [BaseItemDto] {
        if let channelsTask {
            return await channelsTask.value
        }

        let task = Task<[BaseItemDto], Never> { [weak self] in
            guard let userSession = self?.userSession else { return [] }

            var parameters = Paths.GetLiveTvChannelsParameters()
            parameters.userID = userSession.user.id

            do {
                let request = Paths.getLiveTvChannels(parameters: parameters)
                let response = try await userSession.client.send(request)

                return (response.value.items ?? [])
                    .filter { $0.id?.nilIfBlank != nil }
            } catch {
                self?.logger.error("Unable to load live TV channels: \(error.localizedDescription)")
                return []
            }
        }

        channelsTask = task
        let channels = await task.value

        if channels.isEmpty {
            // Allow a retry on the next press
            channelsTask = nil
        } else {
            cachedChannels = channels
        }

        return channels
    }

    // MARK: - Banner

    func dismissBanner(token: Int) {
        guard banner?.token == token else { return }

        banner = nil
    }

    private func showBanner(for channel: BaseItemDto) {
        bannerToken &+= 1

        if let banner, banner.channelID == channel.id {
            self.banner?.token = bannerToken
            return
        }

        let currentProgram = channel.currentProgram.flatMap { program in
            (program.endDate ?? .distantPast) > .now ? program : nil
        }

        banner = Banner(
            channel: channel,
            currentProgram: currentProgram,
            nextProgram: nil,
            token: bannerToken
        )

        programsTask?.cancel()

        guard let channelID = channel.id else { return }

        programsTask = Task { [weak self] in
            guard let self else { return }

            let programs = await self.getPrograms(channelID: channelID)

            guard !Task.isCancelled, self.banner?.channelID == channelID else { return }

            let now = Date.now
            let current = programs.first { program in
                guard let startDate = program.startDate, let endDate = program.endDate else { return false }

                return startDate <= now && now < endDate
            }
            let next = programs.first { program in
                guard let startDate = program.startDate else { return false }

                return startDate > now
            }

            if let current {
                self.banner?.currentProgram = current
            }
            self.banner?.nextProgram = next
        }
    }

    private func getPrograms(channelID: String) async -> [BaseItemDto] {
        guard let userSession else { return [] }

        var parameters = Paths.GetLiveTvProgramsParameters()
        parameters.channelIDs = [channelID]
        parameters.enableImages = false
        parameters.enableTotalRecordCount = false
        parameters.enableUserData = false
        parameters.limit = 3
        parameters.minEndDate = Date.now
        parameters.sortBy = [.startDate]
        parameters.userID = userSession.user.id

        do {
            let request = Paths.getLiveTvPrograms(parameters: parameters)
            let response = try await userSession.client.send(request)

            return response.value.items ?? []
        } catch {
            logger.error("Unable to load programs for channel \(channelID): \(error.localizedDescription)")
            return []
        }
    }
}
