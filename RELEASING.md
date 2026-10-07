# Releasing

Every change to the app on `main` goes to TestFlight by itself. App Store releases are made by
hand, by running a workflow. Both work like the [Android
remote's](https://github.com/clementine-player/Android-Remote/blob/master/RELEASING.md)
development builds and releases.

## TestFlight builds

Every push to `main` that changes the app (not only its tests, docs, CI or store listing)
uploads a build to TestFlight (`.github/workflows/testflight.yml`). The internal testers get it
at once, with no review. Its *What to Test* is the titles of the last 5 commits.

External testers get them too: the group named in the repository variable `TESTFLIGHT_GROUPS`
(*External testers*; several are separated by commas). Their builds go through Apple's Beta App
Review first: the first build of each version gets a full review, which can take a day or so, and
later ones are usually quicker. With each build, the workflow sets:

- the description testers see, from `fastlane/testflight/beta_app_description.txt`
- the notes for Beta App Review: the same as App Review's, with the demo Clementine's address
  and the `DEMO_AUTH_CODE` auth code (see *App Store releases*)

The feedback email and the reviewers' contact are set once in App Store Connect, under
*TestFlight → Test Information*, and left as they are.

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

## Translations

The app is translated on [Transifex](https://app.transifex.com/davidsansome/clementine-remot/), next
to the Android remote, and `.github/workflows/translations.yml` keeps the two in step, as the
Android remote's does:

- When the String Catalog (`App/Resources/Localizable.xcstrings`) changes on `main`, it's
  pushed to Transifex for the translators. Transifex takes the translations in it too, replacing
  its own, so the translations made on Transifex since the last pull are pulled into it first.
- Every night, the translations are pulled back and merged into the catalog
  (`scripts/merge-transifex-translations.py`), and committed to `main` when they changed, as
  "Automatic merge of translations from Transifex". Only translated strings come back, reviewed and
  not reviewed yet alike (each pulled on its own, as one Transifex mode can leave the other
  out), and a translation whose placeholders don't match the English is left out, with a warning. Xcode
  still decides which strings the app has. The commit has a release note, so new translations
  make the next release; however many nights they changed, the release notes say so once.
- Transifex fills in strings whose English it has translated already, for this app or the
  Android remote (its translation memory fill-up): the same wording in both apps is translated
  once.

Translations are made on Transifex, not in pull requests: the next pull would overwrite them.

**One-time setup:**

1. **Transifex:** the project is shared with the Android remote, and its first translations run
   adds the languages: do that first. The catalog is uploaded as one file, and Transifex only
   fills in languages the project has. Make an API token (*User settings → API token*):
   `gh secret set TX_TOKEN --body <token>`. The resource needn't be made by hand: the first
   push makes it.
2. **GitHub:** make a deploy key with write access (*Settings → Deploy keys*), and
   `gh secret set TX_KEY < <private key file>`. If `main`'s branch protection or rulesets would
   refuse the push, let deploy keys bypass them. It pushes as itself so that the other
   workflows run on the commit; the workflow's own token can't start them.
3. **The first time,** run the workflow by hand with *Push translations* ticked: it sends the
   catalog's translations up to Transifex, so translators start from them, then pulls.

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
