# Livin Log

## CloudKit sharing note for TestFlight (required before App Store release)

If you are testing CloudKit share links through TestFlight before the app is approved on the App Store, configure a **Sharing Fallback URL** in CloudKit Dashboard for the production container.

- CloudKit Dashboard → your container → **Settings** → **Sharing Fallback URL**.
- Without this setting, iOS may try to route share acceptance through the App Store and display a “newer version required” message even when both devices are on the same TestFlight build.

Reference: Apple CloudKit sharing documentation.
