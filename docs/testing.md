# Testing Glance

Thanks for trying Glance. It is one app, Glance Studio: a terminal with Glance built in, which also docks Glance over your other terminals.

## Install

1. Download the DMG: https://github.com/gobinda168/glance-releases/releases/download/feed-terminal/Glance-Studio.dmg
2. Open it and **drag the app to Applications**. Run it from Applications, not from the DMG or Downloads, or it can't update itself.
3. The first time only, macOS will say it can't verify the app (it isn't from the App Store or notarized). Right-click the app in Applications → **Open** → **Open**. If that still refuses, run in Terminal:
   `xattr -dr com.apple.quarantine "/Applications/Glance Studio.app"`.
4. Allow Accessibility and Microphone when asked; Glance uses them to dock to your terminal and for hold-fn dictation.
5. **One app, two switches.** Glance Studio now includes the overlay. Settings → APP has **Built-in terminal** and **Overlay on other terminals**, both on by default. Turn the terminal off to run Glance as a menu-bar app only (like Glance.app); turn the overlay off to keep it to its own terminal.

## Updates

New builds arrive on their own. Glance Studio checks every hour and shows **New update available** at the bottom left of its window. **Install Now** downloads the update, then **Restart Now** finishes it. The restart ends whatever is running in your terminals, so it waits for you. **Later** hides that build for a day; if it's already downloaded, it installs the next time you quit. You can also choose Check for Updates… from the app's menu any time.

## Coming from Glance.app

Glance.app is retired: Glance Studio does everything it did (turn off **Built-in terminal** in Settings → APP for a menu-bar-only app). Install Glance Studio once and delete Glance.app; its settings and API keys carry over. Glance.app gets no more updates, and while it runs it holds the port Glance Studio's overlay needs, so quit it first.

## Reporting a problem

Run `"/Applications/Glance Studio.app/Contents/MacOS/glance" version` (or use About in Glance Studio) and include the version and commit it prints.
