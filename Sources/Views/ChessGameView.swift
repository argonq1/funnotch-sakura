import AppKit
import SwiftUI
import WebKit

struct ChessLauncherView: View {
    @EnvironmentObject private var viewModel: NotchViewModel

    var body: some View {
        VStack {
            HStack { NotchGamePicker(); Spacer() }
            Spacer()
            Button { viewModel.openChessWindow() } label: {
                Label("Chess.com", systemImage: "checkerboard.rectangle")
                    .font(.system(size: 19, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .modifier(NotchSurface(radius: 16))
                    .modifier(NotchHoverHighlight(radius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(NotchPressStyle())
            .help("Открыть шахматы в отдельном окне")
            Spacer()
        }
        .padding(.top, 6)
    }
}

struct ChessPanel: View {
    @ObservedObject var session: ChessWebSession

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            ZStack {
                NotchPalette.panel
                if let browser = session.webView {
                    ChessWebHost(browser: browser)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checkerboard.rectangle").font(.system(size: 29)).foregroundStyle(NotchPalette.accent)
                        Text("Chess.com").font(.system(size: 18, weight: .bold))
                        Button("Открыть Chess.com") { session.open(session.destination) }.buttonStyle(.borderedProminent).tint(NotchPalette.accent)
                    }.padding()
                }
                if let error = session.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 24))
                        Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                        HStack {
                            Button("Перезагрузить") { session.reload() }
                            Button("Открыть в браузере") { session.openInBrowser() }
                        }.buttonStyle(.bordered)
                    }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.9))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(NotchPalette.rim, lineWidth: 0.6).allowsHitTesting(false))
                .overlay(alignment: .top) {
                    if session.isLoading { ProgressView().controlSize(.small).padding(8).background(.black.opacity(0.7), in: Capsule()).padding(8).allowsHitTesting(false) }
                }
        }
        .padding(10)
        .background(Color(white: 0.10))
    }
    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(ChessDestination.allCases) { destination in
                    Button { session.open(destination) } label: {
                        Text(destination.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(session.destination == destination ? .black : NotchPalette.secondaryText)
                            .padding(.horizontal, 11).frame(height: 26)
                            .background {
                                if session.destination == destination { Capsule().fill(NotchPalette.selection) }
                            }
                    }.buttonStyle(NotchPressStyle()).accessibilityLabel("Chess.com: \(destination.title)")
                }
            }.padding(2).modifier(NotchSurface(radius: 15))
            Spacer(minLength: 0)
            icon("chevron.left", "Назад на Chess.com", disabled: !session.canGoBack) { session.back() }
            icon("arrow.clockwise", "Перезагрузить Chess.com") { session.reload() }
            Button("Войти") { session.signIn() }.font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
                .foregroundStyle(NotchPalette.accent).padding(.horizontal, 5).help("Войти в аккаунт Chess.com")
            Menu {
                Button("Увеличить страницу") { session.setZoom(session.zoom + 0.1) }
                Button("Уменьшить страницу") { session.setZoom(session.zoom - 0.1) }
                Button("Масштаб 100%") { session.setZoom(1) }
                Divider()
                Button("Открыть в браузере") { session.openInBrowser() }
                Button("Закрыть страницу и освободить память") { session.unload() }
            } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(width: 22, height: 25) }
                .menuStyle(.borderlessButton).fixedSize().help("Масштаб, браузер и выгрузка шахмат")
        }.frame(height: 30)
    }
    private func icon(_ symbol: String, _ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 23, height: 25)
                .modifier(NotchHoverHighlight(radius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label).disabled(disabled)
            .foregroundStyle(.white.opacity(disabled ? 0.25 : 0.75))
    }
}

/// Keep the same WebKit page across window resizes and reopenings.
private struct ChessWebHost: NSViewRepresentable {
    let browser: WKWebView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        browser.removeFromSuperview()
        browser.frame = container.bounds
        browser.autoresizingMask = [.width, .height]
        container.addSubview(browser)
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {
        if browser.superview !== view {
            browser.removeFromSuperview(); browser.frame = view.bounds
            browser.autoresizingMask = [.width, .height]; view.addSubview(browser)
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        view.subviews.forEach { $0.removeFromSuperview() }
    }
}
