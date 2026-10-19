/// The product as users see it: menus, onboarding, VoiceOver, the bundle. The code and the C core
/// keep the project's working name, Nokta (`NoktaEngine`, `nk_*`, `libnokta.a`): it never reaches
/// the screen.
enum Product {
    static let name = "Snapline"
    /// The lower-case wordmark; its red period is drawn apart from it.
    static let wordmark = "snapline"
    /// Info.plist's CFBundleIdentifier (scripts/build-app.sh signs with the same).
    static let bundleID = "com.htahaozlu.snapline"
}
