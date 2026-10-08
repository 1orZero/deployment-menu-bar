# Open Deployment Menu Bar

A macOS menu bar app, with an iOS companion app and widgets, that shows your **Vercel** and **Cloudflare Pages/Workers** deployments. The latest deployment's status sits in the menu bar, and clicking a row opens it in the browser.

![Open Deployment Menu Bar on macOS showing Vercel (black ▲) and Cloudflare (orange ☁) deployment rows](./open-deployment-menu-bar-macos.png)

This project is a fork of [andrewk17/vercel-deployment-menu-bar](https://github.com/andrewk17/vercel-deployment-menu-bar), extended with Cloudflare support.

## Features

- Vercel deployments, plus Cloudflare Pages deployments and Workers deployments. Each row shows the state: queued, building, ready, error, canceled or skipped.
- Workers rows can include Workers Builds status (building, failed, canceled) when the token allows it. Gradual rollouts show the traffic percentage.
- The menu bar shows the newest deployment across both platforms: ▲ for Vercel or ☁ for Cloudflare, followed by a state icon. In the menu, Vercel rows use a black ▲ and Cloudflare rows an orange ☁. A ⚠ appears when one platform has a problem while the other keeps working.
- Per-platform filters: scopes/accounts and projects (checkbox pickers), git branches, Production/Preview, deployment states, and a count or time limit.
- Two menu layouts: all deployments sorted by time, or grouped by platform.
- API tokens are stored in iCloud Keychain, so the Mac app and the iOS app share them. A token added or changed on one device appears on the other.
- iOS app with the same deployment list, filters and layouts, plus home screen widgets (latest deployment, today's status, recent deployments, platform split) and lock screen widgets.
- Native Swift app.

## Installation

### Pre-built release

1. Download the latest release from the [Releases](https://github.com/1orZero/deployment-menu-bar/releases) page.
2. Unzip it and move `Open Deployment Menu Bar.app` to your Applications folder.
3. Launch the app, click its menu bar item and choose **Preferences…** to add your tokens.

### Build from source

Requirements:
- macOS 13.0 or later (Mac app), iOS 17.0 or later (iOS app)
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple Developer team. Every target signs with the team set in `project.yml` (`DEVELOPMENT_TEAM`), because iCloud Keychain sharing needs the same team on every app. Change it to your own team before building.

```bash
git clone https://github.com/1orZero/deployment-menu-bar.git
cd deployment-menu-bar

./Scripts/package-app.sh

# Output: build/Open Deployment Menu Bar.app
```

`project.yml` describes three targets: `OpenDeploymentMenuBar` (Mac), `OpenDeployment` (iOS) and `OpenDeploymentWidgets` (iOS widget extension). `xcodegen generate` writes `OpenDeployment.xcodeproj`, which is not committed. Shared code lives in `Sources/DeploymentCore`; `swift test` runs the unit tests from `Package.swift`.

A binary from `swift build` is unsigned, so it has no keychain access group and cannot read the synced tokens. Use the Xcode targets to run the app.

### Packaging, signing and notarization

`Scripts/package-app.sh` archives the Mac app with automatic signing and exports it. The first run registers the Mac with your team when needed (`-allowProvisioningUpdates`).

- Default (`EXPORT_METHOD=debugging`): signed with your Apple Development certificate. It runs on Macs registered to your team and is not notarized.
- `EXPORT_METHOD=developer-id ./Scripts/package-app.sh`: signed with a Developer ID Application certificate for distribution, then notarized by `Scripts/notarize-app.sh`. Your team needs that certificate.

Notarization also needs an App Store Connect API key:

```bash
export APPLE_API_KEY_ID="your-key-id"
export APPLE_API_ISSUER="your-issuer-id"
export APPLE_API_KEY_PATH="$HOME/.private_keys/AuthKey_XXXXXXXXXX.p8"
```

If these are missing, the script exports the app and skips notarization.

### iOS app

Run `xcodegen generate`, open `OpenDeployment.xcodeproj`, choose the `OpenDeployment` scheme and run it on an iPhone registered to your team. Tokens saved in the Mac app show up on the iPhone once iCloud Keychain has synced them; both devices need Passwords & Keychain turned on in iCloud settings with the same Apple Account.

The iOS app polls on the Mac app's intervals while it is open. Widgets refresh on their own at most every 5 minutes while something is building and every 30 minutes otherwise, because iOS limits how often a widget can reload. Opening the app or tapping a widget's refresh button updates them right away.

The app icon comes from `Resources/AppIcon-source.png` and `Resources/AppIcon.icon`. `Scripts/create-app-icon.sh` regenerates `Resources/AppIcon.icns` and, with Xcode 26 or later (`xcrun actool`), `Resources/Assets.car`. The Mac bundle includes both: `Assets.car` gives the system-masked icon on macOS 26+, and the `.icns` is the fallback for older systems. The iOS app compiles `Resources/AppIcon.icon` directly.

## Configuration

Open **Preferences…** from the menu. The window has three tabs: General, Vercel and Cloudflare. Changes save automatically. A platform without a token is turned off; with no token on either platform the menu bar shows "No Token".

### Vercel

1. Create a token at [Vercel Account Settings → Tokens](https://vercel.com/account/tokens). Copy it right away, because Vercel shows it only once.
2. Paste it into **Vercel API Token** on the Vercel tab.
3. Under **Scope & Project**, keep "All Accessible Scopes" or choose specific team scopes, then keep "All Projects In Scope" or choose specific projects. Both lists are checkbox pickers filled from your token.
4. Optional filters: git branches (comma-separated), Production/Preview, deployment states, and a limit by count or by the last X hours. If both limits are set, the count wins.

### Cloudflare

1. In the Cloudflare dashboard, go to **My Profile → API Tokens** and create a custom token with these read permissions:
   - Account Settings Read
   - Cloudflare Pages Read
   - Workers Scripts Read
2. To see Workers Builds status, the token must be a **user** API token that also has **Workers CI Read**. The Builds API rejects account-owned tokens. Without it, Workers deployments still appear without build status, and the menu bar shows ⚠ with the message "Workers build status needs a user API token with Workers CI Read".
3. Account-owned tokens work for Pages and Workers deployments.
4. Paste the token into **Cloudflare API Token** on the Cloudflare tab.
5. Optional: pick accounts and projects (Pages and Workers appear in one list), then set branch, environment, state (including Skipped) and limit filters.

### General

**Menu Layout** controls how the menu lists deployments:
- **By Time**: both platforms merged, newest first. Problems appear as banners at the top, and the Open Vercel/Cloudflare Dashboard items sit at the bottom.
- **By Platform**: a Vercel section and a Cloudflare section, each with its own banner, deployments and dashboard link.

### Refresh intervals and rate limits

- **Vercel**: every 15 seconds when idle, every 2 seconds while a deployment is building. Both are configurable.
- **Cloudflare**: a full refresh every 30 seconds (minimum 10). While something is queued or building, the app also re-checks only those rows every 5 seconds (minimum 2), one request per row.

Cloudflare allows 1200 API requests per 5 minutes per user. A full refresh costs a few requests per account and one per Worker or Pages project, so many projects with a short interval can hit the limit. Selecting specific accounts and projects cuts the request count. When Cloudflare returns 429, the app pauses all Cloudflare requests until `Retry-After` expires (60 seconds if missing), keeps the last rows, and shows ⚠ with a countdown.

### Tokens and the Keychain

Tokens are synchronizable items in the data protection keychain under the service `com.1orzero.open-deployment-menu-bar`, in the access group `<TEAMID>.com.1orzero.open-deployment.shared`. iCloud Keychain syncs them to your other devices, where the iOS app and its widget read them. Settings and filters stay on each device.

On first launch the Mac app moves tokens from the login keychain (versions up to 0.3.0) into iCloud Keychain. macOS may ask once to allow access to the old items. Settings and a plain-text Vercel token from earlier versions (including the original Vercel Deployment Menu Bar) are migrated too: the token moves to the keychain and is removed from the settings.

## FAQ

### Which platforms are supported?

Vercel, Cloudflare Pages and Cloudflare Workers (including Workers Builds status with a suitable user token).

### Why do my Workers rows have no build status?

The Workers Builds API needs a user API token with Workers CI Read. Account-owned tokens and tokens without that permission still list Workers deployments, but without build status, and the menu bar shows ⚠.

### What does ⚠ in the menu bar mean?

One platform failed (bad token, missing permission, network error, or a Cloudflare rate limit) while the app still has data to show. Open the menu to read the banner. If every enabled platform fails and there is nothing to show, the menu bar shows "Error".

### How do I fix the "damaged app" error on macOS?

Builds exported without Developer ID are not notarized. Right-click the app and choose **Open**, or remove the quarantine attribute:

```bash
xattr -d com.apple.quarantine "/Applications/Open Deployment Menu Bar.app"
```

## License

MIT License. See [LICENSE](LICENSE).

## Disclaimer

Not affiliated with Vercel Inc. or Cloudflare, Inc. Vercel and Cloudflare are trademarks of their respective owners.

## Contributing

Pull requests are welcome.
