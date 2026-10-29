//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import UIKit

protocol WithImageSourceOptions {
    var maxWidth: CGFloat? { get set }
    var maxHeight: CGFloat? { get set }
    var quality: Int? { get set }
}

struct ImageSourceOptions: WithImageSourceOptions {

    var maxWidth: CGFloat?
    var maxHeight: CGFloat?
    var quality: Int? = 90
}

extension CGFloat {

    /// `maxWidth` and `maxHeight` are in points and are scaled by the display scale
    /// when building image requests. Use this to request a fixed pixel size instead.
    static func imagePixels(_ pixels: CGFloat) -> CGFloat {
        pixels / Swift.max(UITraitCollection.current.displayScale, 1)
    }
}
