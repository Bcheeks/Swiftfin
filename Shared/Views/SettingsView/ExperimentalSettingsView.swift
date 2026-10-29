//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import SwiftUI

/// `Note`: Used for experimental settings that may be removed or implemented officially. Keep for future settings.
struct ExperimentalSettingsView: View {

    static let isEnabled = true

    @Default(.Experimental.mpvPlayer)
    private var isMPVEnabled
    @Default(.Experimental.serverConnectionAutoSwitch)
    private var isServerConnectionAutoSwitchEnabled
    @Default(.Experimental.videoPlayerEPG)
    private var isVideoPlayerEPGEnabled
    @Default(.Experimental.liveTVRemoteChannelSwitching)
    private var isLiveTVRemoteChannelSwitchingEnabled
    @Default(.Experimental.liveTVDirectStream)
    private var isLiveTVDirectStreamEnabled
    @Default(.Experimental.liveTVDirectStreamBaseURL)
    private var liveTVDirectStreamBaseURL

    @Injected(\.userSessionManager)
    private var userSessionManager: UserSessionManager

    var body: some View {
        Form(systemImage: "flask") {
            // swiftlint:disable hard_coded_display_string
            Toggle("MPV engine", isOn: $isMPVEnabled)

            Toggle("Live TV EPG", isOn: $isVideoPlayerEPGEnabled)

            #if os(tvOS)
            Toggle("Live TV channel up/down", isOn: $isLiveTVRemoteChannelSwitchingEnabled)
            #endif

            Toggle("Play Live TV directly from ErsatzTV", isOn: $isLiveTVDirectStreamEnabled)

            if isLiveTVDirectStreamEnabled {
                TextField("ErsatzTV URL", text: $liveTVDirectStreamBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            #if os(iOS)
            Toggle("Auto switch connection", isOn: $isServerConnectionAutoSwitchEnabled)
            #endif

            // swiftlint:enable hard_coded_display_string
        }
        .onChange(of: isMPVEnabled) {
            if !isMPVEnabled {
                Defaults[.VideoPlayer.videoPlayerType] = .vlc
            }
        }
        .onChange(of: isServerConnectionAutoSwitchEnabled) {
            if isServerConnectionAutoSwitchEnabled {
                userSessionManager.scheduleServerConnectionResolution()
            }
        }
        .navigationTitle(L10n.experimental)
    }
}
