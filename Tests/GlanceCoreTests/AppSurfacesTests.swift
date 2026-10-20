import Testing
@testable import GlanceCore

@Test func bothSurfacesAreOnByDefault() {
  #expect(AppSurfaces() == AppSurfaces(terminal: true, overlay: true))
}

@Test func theTerminalDecidesTheDockIconAndTheFirstWindow() {
  #expect(AppSurfaces(terminal: true, overlay: false).activationPolicy(configHidesApp: false) == .regular)
  #expect(AppSurfaces(terminal: true, overlay: true).activationPolicy(configHidesApp: true) == .accessory) // macos-hidden = always
  #expect(AppSurfaces(terminal: false, overlay: true).activationPolicy(configHidesApp: false) == .accessory)
  #expect(AppSurfaces(terminal: false, overlay: true).opensWindowAtLaunch == false)
  #expect(AppSurfaces(terminal: true, overlay: false).opensWindowAtLaunch)
}

@Test func reopeningShowsWhateverSurfaceIsOn() {
  #expect(AppSurfaces(terminal: true, overlay: true).reopen() == .showTerminal)
  #expect(AppSurfaces(terminal: false, overlay: true).reopen() == .showOverlay)
  #expect(AppSurfaces(terminal: false, overlay: false).reopen() == .showSettings)
}

@Test func theHotKeysGoToStudioWhenItIsInFrontElseTheOverlay() {
  #expect(AppSurfaces(terminal: true, overlay: true).hotkeyTarget(studioFront: true) == .studioWindow)
  #expect(AppSurfaces(terminal: true, overlay: true).hotkeyTarget(studioFront: false) == .overlay)
  #expect(AppSurfaces(terminal: false, overlay: true).hotkeyTarget(studioFront: true) == .overlay) // only Settings is open
  #expect(AppSurfaces(terminal: true, overlay: false).hotkeyTarget(studioFront: false) == .none)
}

@Test func dictationTypesIntoStudioOrTheFrontApp() {
  let both = AppSurfaces(terminal: true, overlay: true)
  #expect(both.dictationRoute(appActive: true, studioHasFocusedTerminal: true) == .studioTerminal)
  #expect(both.dictationRoute(appActive: true, studioHasFocusedTerminal: false) == .none) // Home or an editor tab
  #expect(both.dictationRoute(appActive: false, studioHasFocusedTerminal: false) == .frontApp)
  let terminalOnly = AppSurfaces(terminal: true, overlay: false)
  #expect(terminalOnly.dictationRoute(appActive: false, studioHasFocusedTerminal: false) == .none)
  let overlayOnly = AppSurfaces(terminal: false, overlay: true)
  #expect(overlayOnly.dictationRoute(appActive: true, studioHasFocusedTerminal: false) == .frontApp) // Settings in front
}

@Test func theOverlayHidesForStudioButNotForASettingsOnlyApp() {
  #expect(AppSurfaces(terminal: true, overlay: true).treatsOwnAppAsFront == false)
  #expect(AppSurfaces(terminal: false, overlay: true).treatsOwnAppAsFront)
}

@Test func settingsCardsFollowTheSwitches() {
  let s = AppSurfaces(terminal: true, overlay: false)
  #expect(s.showsTerminalCards && !s.showsOverlayCards)
}
