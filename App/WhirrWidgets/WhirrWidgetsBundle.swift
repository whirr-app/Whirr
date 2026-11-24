//
//  WhirrWidgetsBundle.swift
//  WhirrWidgets
//
//  Created by Rhys Thomas on 06/11/2026.
//

import SwiftUI
import WidgetKit

@main
struct WhirrWidgetsBundle: WidgetBundle {
  var body: some Widget {
    ContinueListeningWidget()
    NewEpisodesWidget()
    SmartListWidget()
    ListeningStatsWidget()
    ListeningAccessoryWidget()
    PlayPauseControl()
    SleepTimerControl()
    SkipBackControl()
    SleepTimerLiveActivity()
  }
}
