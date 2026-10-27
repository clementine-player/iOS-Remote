/// Whether this build has the features that are still being built: debug builds and TestFlight
/// builds do, App Store releases never. TestFlight builds are built with the `TESTING_FEATURES`
/// condition (see `scripts/archive.sh` and `.github/workflows/testflight.yml`).
public enum TestingFeatures {
    #if DEBUG || TESTING_FEATURES
    public static let enabled = true
    #else
    public static let enabled = false
    #endif
}
