// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// The two attachment choices of an export (A9), shown at the end of every export menu. They apply to Markdown and
/// TextBundle; an HTML export always carries its pictures. The list's export menu also shows the note link switch here.
struct MobileExportChoices: View {
    @Bindable var library: MobileLibrary
    var showsNoteLinks = false
    var body: some View {
        Divider()
        if showsNoteLinks {
            Toggle("Note Links in HTML", isOn: $library.preferences.relativeWikiLinksOnExport)
        }
        Toggle("Include Attachments", isOn: $library.preferences.exportIncludeAttachments)
        Toggle("Images Inside File", isOn: $library.preferences.exportEmbedImages)
            .disabled(!library.preferences.exportIncludeAttachments)
    }
}
