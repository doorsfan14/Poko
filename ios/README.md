# Poko for iOS

Poko's iOS client is a native SwiftUI application. It does not load the website, embed a browser, or use a web view.

## Build

The repository includes a GitHub Actions workflow at `.github/workflows/ios.yml`. Every push or pull request that changes `ios/**` builds a Release iOS Simulator app and uploads `Poko-iOS-Simulator.zip` as a workflow artifact.

For a local build:

1. Install Xcode 16 or newer and XcodeGen.
2. From the repository root, run `xcodegen generate --spec ios/project.yml`.
3. Open `ios/Poko.xcodeproj` in Xcode or build it with `xcodebuild -project ios/Poko.xcodeproj -scheme Poko -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.

## Firebase setup

Register a separate iOS app in the existing Firebase project using bundle identifier `com.teamceleris.poko`. Download its `GoogleService-Info.plist` and add it to the `ios/Poko` target in Xcode. Add the plist's `REVERSED_CLIENT_ID` as a URL Type URL Scheme in the app target so Google Sign-In can return to Poko. Enable Google as a Firebase Authentication provider and keep the existing Firestore rules deployed.

The iOS-specific plist is intentionally not committed. The web app's Firebase configuration contains a web app ID and cannot be reused as the iOS app registration.

## Native features

The SwiftUI client includes Google authentication, live Firestore conversation lists and messages, direct and group conversation creation, friends and incoming friend requests, profile name/bio editing, theme selection, and sign-out. It uses the same Firestore collections and document fields as the existing Poko web client.
