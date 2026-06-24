# WhiteNoise iOS — Manual Test Matrix

These checks complement the automated test suites (`whitenoise-iosTests`
Swift Testing module and `marmot-uniffi`'s Rust integration tests). They
cover the user-visible flows that aren't economical to automate yet.

Run them whenever the FFI surface or onboarding flow changes, and once
before every release tag.

## Setup

- Two simulators (or one simulator + one device) on the same network with
  outbound access to your default relay set. Spin up a second simulator
  with: `xcrun simctl boot "iPhone 17 Plus"` then `xcodebuild` the app
  for both targets.
- Clean install on each: `xcrun simctl erase <udid>` between runs.

## Onboarding

- [ ] Cold launch on a clean install lands on **Welcome** within ~1s.
- [ ] **Create New Identity** generates a new account, shows the npub, and
      Continue lands in the empty Chats screen.
- [ ] **Import Existing nsec** with a valid `nsec1…` succeeds and lands in
      Chats; the account appears in Settings → Accounts.
- [ ] Pasting a `npub1…` into the import flow cannot be submitted; npub values
      are public identifiers, not sign-in credentials.
- [ ] Importing with garbage (random string) surfaces an error toast at
      the top of the screen and stays on the Import screen.
- [ ] Force-quit + relaunch after onboarding lands directly on Chats; the
      Welcome screen does not reappear.

## Multi-account

- [ ] Settings → Accounts → Add launches the Welcome flow inside a sheet.
- [ ] Creating a second account flips the active account ref to the new
      one; Chats now shows that account's (empty) list.
- [ ] Tapping the chats toolbar avatar shows the account switcher menu
      with both accounts; switching updates the chats list.
- [ ] Each account's chats are isolated — a group created from account A
      does not appear in account B's list.

## Chats & messaging (2-member group, DM appearance)

- [ ] On device A, **New chat** → paste device B's npub → Create. Toast
      reports success.
- [ ] Device A sees the new chat in its list with device B's identity
      rendered as the row title.
- [ ] Device B's chat list shows the new group within a few seconds
      without a manual refresh (Welcome flow).
- [ ] Device A sends a message; device B sees it in their conversation
      view within a few seconds. Sender bubble is right-aligned on A,
      left-aligned on B.
- [ ] Reverse direction works too.
- [ ] Force-quit + relaunch device A; conversation history reappears
      from local SQLCipher storage.

## Markdown rendering

- [ ] Send `**bold** _italic_ ~~strike~~ \`code\``: both sides render
      styled text (no literal asterisks); the sent bubble stays white-on-
      gradient, received stays primary-on-gray, in light and dark mode.
- [ ] Send a fenced code block, a `> quote`, a bulleted + numbered list,
      and a `- [x]` task list: block chrome renders (code background,
      quote bar, markers) and the bubble does not balloon to full width.
- [ ] Send `[label](https://example.com)`: link is underlined; tapping
      opens Safari; long-press on the bubble still opens the actions
      sheet.
- [ ] Send `[x](javascript:alert(1))`: renders as plain text, nothing
      happens on tap.
- [ ] Send a message with an image attachment plus a markdown caption:
      caption renders styled under the media grid.
- [ ] Chat list row and reply quote show the message with markdown
      syntax stripped (`bold text`, not `**bold** _text_`).
- [ ] An npub mention of a group member renders as bold `@Display Name`
      and opens their profile on tap; an unknown npub shows the truncated
      `@npub1…` form (and upgrades to the name once the profile fetch
      lands); a `nostr:note1…` reference renders monospaced and inert.
- [ ] Chat-list preview and reply quote show `@Display Name` for
      mentions, not the npub.

## Groups (3+ members)

- [ ] Device A creates a 3-member group (B + C). Roster on A shows
      all 3 members. Group renders by name (not DM-style).
- [ ] B and C both see the group within a few seconds.
- [ ] B sends a message; A and C both receive it; the sender bubble
      shows B's display name (when projected via kind:0).
- [ ] A invites a 4th member (D); A/B/C see the roster grow plus an
      inline "Membership changed" system row.
- [ ] Group Details: an admin can add members using npub/hex/profile
      links, promote a member, remove admin status, and remove a member.
- [ ] Group Details: a non-admin sees the member list but no add/manage
      controls.
- [ ] Group Details: an admin must step down before leaving; the last
      admin cannot step down until another admin exists.
- [ ] D launches the app and sees the group materialize without manual
      refresh.
- [ ] A removes C; C loses access; A/B see the system row.
- [ ] A leaves the group; B/C see the system row; A's row vanishes
      from their Chats list.

## Settings & profile

- [ ] Settings → account row: filling in display name + about + picture URL
      and tapping **Publish to Relays** shows a success toast.
- [ ] After publish, the profile name appears in conversation sender
      labels for that account on a fresh device.
- [ ] Settings → Relays: adding `wss://…` or `ws://…` accepts, publishes
      through Marmot, and refreshes the published NIP-65/inbox
      lists; other schemes reject.
- [ ] Settings → Identity: tapping the Public key and npub rows copies the
      full value and shows the inline **Copied** state.
- [ ] Settings → QR button opens **My Code**; tapping the npub copies it,
      the share button shares a `darkmatter://profile/<npub>` link, and
      Scan QR Code routes a valid profile QR to the profile sheet.
- [ ] Settings → Identity → Sign out removes the active account and its
      local key material from the device; with multiple accounts, the app
      switches to the next account, and with one account it returns to
      onboarding.
- [ ] Group Details → Set/Edit group image rejects non-HTTPS, localhost,
      private-address, and invalid URLs; a public HTTPS image URL previews
      and saves.
- [ ] Group Details → Set/Edit group image → Search the web shows the
      DuckDuckGo/image-host disclosure, returns selectable results, and
      saves the selected public HTTPS result.

## Privacy, audit, and telemetry

- [ ] Settings → Privacy & Security: toggling **Anonymous Telemetry**
      persists and does not restart or strand the running app.
- [ ] Settings → Privacy & Security: enabling **Audit Logging**, sending a
      message, and returning to the screen lists a local audit JSONL file.
- [ ] Settings → Privacy & Security: **Delete All Audit Logs** clears the
      listed files; if audit logging remains enabled, new activity rotates
      into a fresh file.
- [ ] Settings → Privacy & Security: **Developer mode** reveals Streaming
      debug and **Open Diagnostics**; disabling it hides those controls.
- [ ] With Developer mode on, Group Details → Export Conversation
      Transcript opens the share sheet for a JSON file; dismissing the
      share sheet removes the temporary export file.

## Notifications

- [ ] Settings → Notifications: enabling Local notifications prompts for
      system notification permission and persists the enabled state.
- [ ] Settings → Notifications: enabling Native push requests an APNS token,
      syncs a redacted token fingerprint, and does not expose the raw token.
- [ ] While device B is outside the app, sending a message from device A
      causes device B to receive a generic APNS wake that is rewritten by the
      Notification Service Extension into sender/message text.
- [ ] Tapping that notification opens the matching chat for the matching
      account.
- [ ] Sending a message in a chat that device B is already viewing does not
      show a duplicate local banner while the app is foreground-active.
- [ ] A generic APNS wake with no local notification update shows a coherent
      generic fallback notification, not a blank title/body.

## Diagnostics

- [ ] Settings → Privacy & Security → Developer mode → Open Diagnostics.
      **Live** indicator pulses green.
- [ ] Send to self creates a 1-member group and logs the send-to-self
      line in the event log.
- [ ] Clear empties the log; turning Developer mode off hides the
      diagnostics entry.

## Lifecycle / backgrounding

- [ ] Background the app (Home/app switcher) and leave it for ~30s, then
      reopen: it resumes without relaunching (chats/messages still bound,
      no onboarding screen).
- [ ] Repeat the background/foreground cycle several times in a row: the app
      never crashes on backgrounding (regression for the `0xdead10cc`
      suspension kill — the runtime must release its shared-container SQLite
      storage on background and rebuild it on foreground).
- [ ] After resuming from background, sending a message and receiving one
      both still work (the runtime restarted, not just woke a dead handle).

## Offline / failure

- [ ] Turning off Wi-Fi mid-conversation: sending a message shows an
      error toast; reconnecting and tapping send again succeeds.
- [ ] Invalid recipient npub in **New chat** surfaces an error toast
      and stays on the sheet.

## Accessibility & visual

- [ ] Dark Mode (Settings.app → Display) renders all screens correctly
      with no white-on-white text.
- [ ] Dynamic Type (XL): chat rows, conversation bubbles, settings
      cells all scale; no truncation that hides actionable text.
- [ ] Visual material: on iOS 26, navigation bars and the composer use Liquid
      Glass; on iOS 18, the composer uses the material fallback with no
      flat-white toolbar.
- [ ] VoiceOver: every primary action has a label (compose, send,
      group details, account switcher).
