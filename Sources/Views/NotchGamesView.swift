import SwiftUI

enum NotchGame: String, CaseIterable, Identifiable {
    case drift, chess
    var id: String { rawValue }
    var title: String { self == .drift ? "Hellcat Afterdark" : "Chess.com" }
    var symbol: String { self == .drift ? "steeringwheel" : "checkerboard.rectangle" }
}

struct GameView: View {
    @EnvironmentObject private var settings: Settings
    var body: some View {
        if settings.notchGame == .chess && !DriftGame.shared.isPerformanceProbe && !Motion.snapshotMode {
            ChessLauncherView()
        } else {
            DriftGameView()
        }
    }
}

struct NotchGamePicker: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var viewModel: NotchViewModel
    var body: some View {
        Menu {
            ForEach(NotchGame.allCases) { game in
                Button {
                    withAnimation(.notchContent) { settings.notchGame = game }
                    if game == .chess { viewModel.openChessWindow() }
                } label: {
                    Label(game.title, systemImage: settings.notchGame == game ? "checkmark.circle.fill" : game.symbol)
                }
            }
        } label: {
            Image(systemName: settings.notchGame.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .modifier(NotchSurface(radius: 10))
        }.menuStyle(.borderlessButton).fixedSize()
            .help("Выбрать игру: Hellcat или Chess.com")
            .accessibilityLabel("Выбрать игру. Сейчас: \(settings.notchGame.title)")
    }
}

extension NotchViewModel {
    func openChessWindow() {
        guard !FocusManager.shared.isActive else { return }
        ChessWindowController.shared.show(on: screen)
        close()
    }
}
