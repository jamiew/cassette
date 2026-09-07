// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import GoogleCast
import SwiftUI

/// The Cast SDK's own device picker button.
///
/// Always visible, matching AirPlay: the SDK presents a "searching for devices"
/// sheet when nothing has been discovered yet, which reads better than a control
/// that appears and disappears as devices come and go on the network.
struct CastButton: UIViewRepresentable {
    var tintColor: Color

    func makeUIView(context _: Context) -> GCKUICastButton {
        let button = GCKUICastButton()
        button.tintColor = UIColor(tintColor)
        button.backgroundColor = .clear
        return button
    }

    func updateUIView(_ button: GCKUICastButton, context _: Context) {
        button.tintColor = UIColor(tintColor)
    }
}
#endif
