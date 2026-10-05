# Releasing

Every change to the app on `main` goes to TestFlight by itself. App Store releases are made by
hand, by running a workflow. Both work like the [Android
remote's](https://github.com/clementine-player/Android-Remote/blob/master/RELEASING.md)
development builds and releases.

## TestFlight builds

Every push to `main` that changes the app (not only its tests, docs, CI or store listing)
uploads a build to TestFlight (`.github/workflows/testflight.yml`). The internal testers get it
at once, with no review. Its *What to Test* is the titles of the last 5 commits.

To send builds to external testers as well, create their group in App Store Connect and set the
repository variable `TESTFLIGHT_GROUPS` to its name (or several, separated by commas). Apple
reviews the first build an external group gets.

## App Store releases

**Release notes live in commit messages.** A commit that changes something users notice ends
with a `Release-note:` trailer: one line, written for users (what's new, not how it was done):

```
Show the song's lyrics in the player

Release-note: The player shows the song's lyrics, when Clementine finds them.
```

Commits without one (refactoring, tests, CI, docs) don't need one. A change made in both
clients can have the same note in both.

**To release,** run the release workflow on `main` (*Actions → release → Run workflow*,
`.github/workflows/release.yml`). It releases `main` as it is:

- It builds the app, uploads it to App Store Connect, and pushes the tag `v<version>`.
- It takes the App Store screenshots: light, on a 6.9" iPhone and a 13" iPad, which the
  App Store scales for smaller ones. These are `UITests/Screenshots.swift`, as on pull requests
  (`.github/workflows/screenshots.yml`), against a real Clementine playing the showcase library.
  Up to 10 per device, so the settings screen is left out; the order is in `release.yml`.
- It submits the build for App Review, with the listing in `fastlane/metadata`, the
  screenshots, and the release notes: the notes of every commit since the last release, or
  "Fixes and improvements." when none has one. Once Apple approves it, it's released.
- It publishes a GitHub release with the notes.

To see what the next release would be, run `scripts/plan_release.sh`.

If a release failed after its tag was pushed (App Review's submission failed, say), run the
workflow again with that tag: it finishes publishing it, without uploading the build again.

**Versions.** Releases are numbered from `MARKETING_VERSION` in `project.yml`: 1.0, then 1.1,
1.2 and so on, each the first that has no tag yet (`scripts/version.sh`). TestFlight builds
carry the version of the next release, since App Store Connect takes no more builds of a version
once it's released. For a major version, change `MARKETING_VERSION` to 2.0. Build numbers come
from `main`'s commit count: twice it for TestFlight builds, and one more for a release, so every
upload's is higher than the one before.

**The listing** is in `fastlane/metadata`: the name, subtitle, description, keywords and links
in `en-US/`, and the notes for App Review in `review_information/`. Each release uploads it as
it is, so change it there rather than in App Store Connect.

**App Review needs a Clementine** to try the app with. It gets the demo Clementine,
`demo.clementine-player.org`, which the Android remote's reviewers use too: a Clementine on
Google Cloud playing the showcase library, set up as the Android remote's
[RELEASING.md](https://github.com/clementine-player/Android-Remote/blob/master/RELEASING.md#demo-clementine-for-store-reviewers)
says. Each release adds its address and auth code to the notes for App Review. The auth code is
the repository secret `DEMO_AUTH_CODE`, never committed: anyone with it can control the demo.
Without it, the release workflow releases nothing.

## How it signs in

There are no certificates or provisioning profiles in the repository or its secrets.
`scripts/archive.sh` builds the archive unsigned, and Xcode's cloud signing signs it as it's
exported, with a distribution certificate Apple keeps and the profiles Xcode makes as it needs
them. Before that, it signs the app and the widget ad hoc with their entitlements (the app group
they share), which the export keeps.

The workflows sign in to App Store Connect with an API key, in three repository secrets:

| Secret            | What                                   |
|-------------------|----------------------------------------|
| `ASC_KEY_ID`      | The key's ID                           |
| `ASC_ISSUER_ID`   | The issuer ID, above the list of keys  |
| `ASC_PRIVATE_KEY` | The contents of the key's `.p8` file   |

Until they're set, the TestFlight workflow builds nothing, and the release workflow releases
nothing, each with a notice saying so.

`fastlane/Fastfile` talks to App Store Connect: it uploads the builds, sets their changelog, and
submits releases. To run `scripts/archive.sh` on your own Mac, sign in to Xcode with an account
on the team: it signs with that account.

## One-time setup

1. **Create the app** in [App Store Connect](https://appstoreconnect.apple.com): *Apps → + →
   New App*, iOS, named *Clementine Remote*, English (U.S.), with the bundle ID
   `org.clementine-player.remote`.
2. **Make the API key:** *Users and Access → Integrations → App Store Connect API → Team
   Keys*, with the *Admin* role, which cloud signing needs. Download the `.p8` (it can only be
   downloaded once) and set the secrets:

   ```sh
   gh secret set ASC_KEY_ID --body <key ID>
   gh secret set ASC_ISSUER_ID --body <issuer ID>
   gh secret set ASC_PRIVATE_KEY < AuthKey_<key ID>.p8
   ```

3. **TestFlight:** under *TestFlight → Internal Testing*, create a group with *Enable automatic
   distribution* on, and add the testers. They need to be users of the App Store Connect team.
4. **Before the first release,** fill in what App Store Connect asks for once rather than with
   each version:
   - *App Privacy:* link to [PRIVACY.md](PRIVACY.md) (the listing does too), and answer that
     the app collects no data.
   - *App Information:* the age rating questionnaire (no objectionable content).
   - *Pricing and Availability:* free, in every country.
   - *App Review Information*, on the version page: a contact's name, phone number and email.
     The notes for the reviewer, which explain that the app needs Clementine and how to use the
     demo Clementine, are in `fastlane/metadata/review_information/notes.txt`.
   - The demo Clementine's auth code, which its setup prints, as the secret
     `DEMO_AUTH_CODE`: `gh secret set DEMO_AUTH_CODE --body <auth code>`.
5. If `v*` tags get a repository ruleset, let GitHub Actions bypass it: the release workflow
   pushes the tags.
6. Run the *testflight* workflow (*Actions → testflight → Run workflow*, on `main`) to check
   it.
