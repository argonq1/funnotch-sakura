//
//  WeatherPane.swift
//  FunNotch
//
//  The dedicated weather tile next to the Home player.
//

import SwiftUI

struct WeatherPane: View {
    var compact = false
    var integrated = false
    @ObservedObject private var weather = WeatherManager.shared

    private var scene: WeatherScene {
        guard let conditions = weather.conditions else { return .cloudy }
        return WeatherScene.from(code: conditions.weatherCode, isDay: conditions.isDay)
    }

    private var isNight: Bool { !(weather.conditions?.isDay ?? true) }

    var body: some View {
        ZStack {
            if !integrated {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.15, blue: 0.20),
                                               SakuraTheme.base],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            GeometryReader { proxy in
                SakuraBlossoms(width: proxy.size.width, height: proxy.size.height,
                               opacity: compact ? 0.55 : 0.7)
            }.allowsHitTesting(false)
            }
            content
                .padding(.horizontal, compact ? 10 : 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(NotchPalette.rim, lineWidth: integrated ? 0 : 0.6).allowsHitTesting(false))
        .animation(.easeInOut(duration: 0.9), value: "\(scene)-\(isNight)")
        .onAppear { weather.addSubscriber() }
        .onDisappear { weather.removeSubscriber() }
    }

    @ViewBuilder
    private var content: some View {
        if weather.conditions != nil {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                    Text(weather.temperatureText ?? "—")
                        .font(.system(size: compact ? 23 : 34, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.97))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: weather.temperatureText)

                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: scene.systemSymbol)
                    .symbolRenderingMode(.hierarchical).foregroundStyle(SakuraTheme.accent)
                    .font(.system(size: compact ? 22 : 40, weight: .light))
                    .accessibilityLabel(scene.localizedLabel)
            }
        } else {
            if !weather.isLocationAuthorized {
                weatherAction("location.slash", "Разрешить геопозицию для погоды") { weather.requestAccess() }
            } else if let error = weather.lastError, !weather.isLoading {
                weatherAction("arrow.clockwise", error) { weather.retry() }
            } else {
                Image(systemName: "cloud")
                    .font(.system(size: compact ? 18 : 26, weight: .light))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .accessibilityLabel("Загружаю погоду")
            }
        }
    }

    private func weatherAction(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 19 : 25, weight: .light))
                .foregroundStyle(SakuraTheme.accent)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}
