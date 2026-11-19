//
//  Sizing.swift
//  FunNotch
//
//  Geometry constants and the per-display notch measurements everything else
//  is laid out against.
//

import AppKit
import SwiftUI

/// Extra room around the panel so drop shadows are not clipped.
let shadowPadding: CGFloat = 20

/// Size of the expanded notch content area. A little roomier than the
/// reference app's 640×190 so nothing crowds the rounded corners.
let openNotchSize = CGSize(width: 690, height: 216)
let gameNotchSize = CGSize(width: 690, height: 378)
/// Room for the menu bar above a panel on a display with a camera cutout.
let notchMenuBarAllowance: CGFloat = 64
/// The window is always big enough to hold the embedded game plus shadow — on
/// every side, not just below. Without the horizontal margin the open notch is
/// drawn flush against the window edge, so its shadow is clipped to nothing and
/// the panel ends in a hard vertical seam instead of fading out.
let windowSize = CGSize(
    width: openNotchSize.width + shadowPadding * 2,
    height: gameNotchSize.height + shadowPadding + notchMenuBarAllowance
)

/// Top radii are the *concave* flares where the panel meets the screen edge.
/// They read much larger than they measure, so the opened one is kept modest —
/// at 19 the panel looked scooped out at both ends.
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) =
    (opened: (top: 11, bottom: 24), closed: (top: 5, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13, closed: 4)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

let downloadSneakSize = CGSize(width: 65, height: 1)
let batterySneakSize = CGSize(width: 160, height: 1)

/// Horizontal padding used inside the expanded notch.
let contentSpacing: CGFloat = 16

extension NSScreen {
    /// A stable identifier for the display, used to remember the user's choice.
    var displayIdentifier: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return localizedName
        }
        return "\(localizedName)-\(number.uint32Value)"
    }

    /// True when the display has a physical notch cutting into the menu bar.
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }

    static func screen(withIdentifier identifier: String) -> NSScreen? {
        NSScreen.screens.first { $0.displayIdentifier == identifier }
    }
}

/// Uses the hardware cutout on a MacBook and the configured size on other displays.
@MainActor
func measureClosedNotch(for screen: NSScreen?) -> CGSize {
    let settings = Settings.shared
    var notchHeight: CGFloat = settings.nonNotchHeight
    var notchWidth: CGFloat = 185

    guard let screen else { return CGSize(width: notchWidth, height: notchHeight) }

    if screen.hasPhysicalNotch {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(1, right.minX - left.maxX)
        }
        return CGSize(width: notchWidth, height: screen.safeAreaInsets.top)
    }

    if settings.nonNotchHeightMode == .matchMenuBar {
        notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
    }
    if settings.nonNotchStyle == .island {
        notchWidth = settings.islandWidth
        notchHeight += settings.islandTopGap
    }

    return CGSize(
        width: notchWidth + settings.notchWidthPadding * 2,
        height: max(notchHeight, 1)
    )
}

/// The display the notch should currently live on.
@MainActor
func preferredScreen() -> NSScreen? {
    let settings = Settings.shared

    if settings.automaticallySwitchDisplay {
        // Follow the display containing the pointer, falling back to the main one.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main
    }

    if !settings.preferredScreenName.isEmpty,
       let screen = NSScreen.screen(withIdentifier: settings.preferredScreenName) {
        return screen
    }

    return NSScreen.screens.first(where: \.hasPhysicalNotch) ?? NSScreen.main
}
