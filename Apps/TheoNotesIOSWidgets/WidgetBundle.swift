// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import WidgetKit

@main struct TheoNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        NewNoteWidget()
        PinnedNoteWidget()
        NoteListWidget()
        SearchWidget()
        NextUpWidget()
        NewTodoWidget()
        LastOpenedWidget()
        ThoughtControl()
        VoiceControl()
        NewNoteControl()
        NewTodoControl()
        ScanControl()
        SearchControl()
    }
}
