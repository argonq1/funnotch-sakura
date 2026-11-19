import SwiftUI

struct MediaSourceMenu: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var settings = Settings.shared
    var body: some View {
        Menu {
            Button { music.selectSource(nil) } label: {
                Label("Автоматически", systemImage: settings.lockedMediaSource.isEmpty ? "checkmark" : "waveform")
            }
            Section("Приложения") {
                ForEach(music.availableSources) { source in
                    Button { music.selectSource(source) } label: {
                        Label(source.rawValue, systemImage: settings.lockedMediaSource == source.rawValue ? "pin.fill" : "app")
                    }
                }
            }
            if !music.browserTabs.isEmpty {
                Section("Закрепить вкладку") {
                    ForEach(music.browserTabs) { tab in
                        Button { music.selectBrowserTab(tab.id) } label: {
                            Label(tab.title + " · " + tab.browser,
                                  systemImage: settings.lockedBrowserTab == tab.id && settings.lockedMediaSource == MediaControllerType.browser.rawValue ? "pin.fill" : "play.rectangle")
                        }
                    }
                }
            }
            Button("Обновить источники") { music.refreshSourceChoices() }
            Button("Открыть источник") { music.openPlayingApp() }.disabled(music.track.isEmpty)
        } label: {
            Image(systemName: settings.lockedMediaSource.isEmpty ? "waveform" : "pin.fill")
                .font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Источник воспроизведения").accessibilityLabel("Выбрать и закрепить источник воспроизведения")
        .onAppear { if !Motion.snapshotMode { music.refreshSourceChoices() } }
    }
}
