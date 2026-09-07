# White Noise iOS — Manual Test Matrix

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

## Imported-account setup

- [ ] Import a valid nsec: the setup checklist opens before network preflight,
      and the key field and matching clipboard contents are cleared.
- [ ] A healthy account progresses to the one-device notice. Continue
      publishes the first local KeyPackage without a second approval; Open Chats
      becomes available only after MDK reports ready.
- [ ] Test all device-discovery outcomes: none found, possible other installation,
      and inconclusive. None found uses Continue; the other two use Continue
      anyway. Every outcome requires the notice; no physical device or last-active
      time is inferred from public package records.
- [ ] Missing or unreadable follows are skipped automatically without publishing
      a list. Empty follows are valid. Skipped rows show a neutral dash.
- [ ] A missing profile offers Update profile or Not now. Update opens the same
      avatar/name/about form as sign-up, without creating another identity. Save
      publishes the entered profile and dismisses only after success; a failed
      save keeps the form and draft visible. Not now publishes nothing.
- [ ] A failed relay lookup offers retry/discovery-source changes without
      treating the failure as missing settings. A missing relay/inbox list offers
      Look on another relay or Use default relays. The latter explains publication
      and shows relay.eu.whitenoise.chat and relay.us.whitenoise.chat before saving.
- [ ] Enter another discovery relay: lookup does not publish any settings. A failed
      or inconclusive lookup does not enable default-relay publication.
- [ ] For both relay-list and inbox-list recovery, search a reachable relay that
      returns no declaration. After any earlier checks finish, Use default relays
      remains available alongside Look on another relay. Defaults publish only
      after the user chooses them; a timeout is not an empty result.
- [ ] Change a record while its form/card is open: MDK rejects stale publication
      instead of silently overwriting the changed record.
- [ ] Interrupt an approved repair or KeyPackage publication, then retry. The
      saved publication resumes without another nsec prompt or duplicate approval.
- [ ] Background during checks and during the notice; relaunch during setup.
      Progress returns, no normal account work starts early, and storage closes
      correctly on background.
- [ ] Cancel setup: the identity remains saved and signed out. Completed repairs
      remain. Interrupted cancellation finishes on resume.
- [ ] Add a second account: the existing account remains selected until setup
      completes. Later returns to it; Finish account setup resumes the checklist.
- [ ] With multiple unfinished identities, Finish account setup offers each one.
      Switch between them; cancel/remove one and verify it disappears from the
      setup choices while the others remain accessible.
- [ ] Finish setup or reconnect while the runtime is quiet: neither action waits
      indefinitely for another network event. Background/resume still drains work.
- [ ] A restored proposal with any unsafe relay address blocks publication of the
      whole proposal and offers Back; it never silently omits the unsafe entry.
- [ ] Verify Dynamic Type, VoiceOver, and Reduce Motion on the checklist and
      repair forms, including long relay lists.

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
- [ ] Send a message long enough to wrap and expand it with **Read more**:
      body text uses the bubble's available width, metadata remains trailing
      below it, and the visible timeline position does not jump.
- [ ] Reopen a long conversation containing multiple wrapped messages and
      media rows: the latest messages are visible immediately at the bottom;
      the timeline never opens blank or requires a scroll gesture to recover.
- [ ] Open a chat with unread history: the unread divider is aligned at the
      top. Open a fully-read chat: the latest-message sentinel is aligned at
      the bottom. Neither entry path flashes or later jumps to another anchor.

## GIF search and remote playback

- [ ] With a local `GIPHY_API_KEY_WHITENOISE_IOS` configured, open the
      composer **+** drawer and choose **GIF**. The sheet explains the GIPHY
      network disclosure and shows the required GIPHY branding.
- [ ] Search for a phrase containing spaces or punctuation, choose a result,
      and confirm visible search tiles begin looping promptly. Choose a result
      and confirm it sends as one message whose bubble loops without sound.
- [ ] On the receiving device, opening the chat does not contact or load the
      GIF. Tapping **Load GIF** loads and loops it; the chat-list preview says
      **GIF via GIPHY** instead of exposing the media URL.
- [ ] Enable Settings → Data & Storage → Automatically Load Remote GIFs and
      confirm received GIFs then load on opening a chat. Disable it and confirm
      the tap-to-load behavior returns.
- [ ] Reply to a message and choose a GIF. Confirm the reply context remains
      attached and the GIF bubble renders without shifting nearby rows.
- [ ] Send landscape, square, and portrait GIFs. Confirm each follows its
      source aspect ratio, meets the bubble's rounded edges without
      letterboxing, and loads visibly sharper than its search thumbnail.
- [ ] With no GIPHY key configured, the GIF drawer action explains that search
      is unavailable and no network request is made.

## Markdown rendering

- [ ] Send `**bold** _italic_ ~~strike~~ \`code\``: both sides render
      styled text (no literal asterisks); the sent bubble stays white-on-
      gradient, received stays primary-on-gray, in light and dark mode.
- [ ] Send a fenced code block, a `> quote`, a bulleted + numbered list,
      and a `- [x]` task list: block chrome renders (code background,
      quote bar, markers) and the bubble does not balloon to full width.
- [ ] Make list items and formatted lines long enough to wrap: no text is
      clipped at the trailing edge before or after expanding the message.
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
      the share button shares a `whitenoise://profile/<npub>` link, and
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

## App lock

Run on a device with a passcode set (and Face ID/Touch ID enrolled for the
biometric paths); the simulator can fake enrollment via Features → Face ID.

- [ ] Settings → Privacy & Security: enabling **Require Face ID** prompts
      for authentication first; cancelling the prompt leaves the toggle off.
- [ ] With the lock enabled, opening the app switcher covers the app's
      card with the splash-style shield; no chat content is visible.
- [ ] With Auto-lock **Immediately**, backgrounding and returning shows
      the locked shield and auto-prompts Face ID; unlocking reveals the
      app in its previous state.
- [ ] With Auto-lock **After 1 minute**, backgrounding and returning
      within a minute skips the prompt; returning after a minute locks.
- [ ] Cancelling the unlock prompt keeps the shield up; **Unlock** retries
      authentication. Content underneath (sheets included) stays hidden.
- [ ] Force-quit + relaunch with the lock enabled starts locked regardless
      of the Auto-lock setting.
- [ ] While locked, a tapped notification still routes to the right chat
      after unlocking.
- [ ] On a device without a passcode, the toggle is greyed out with the
      explanatory footer.

## Screen capture

- [ ] Settings → Privacy & Security: with **Block screenshots** on, a
      screenshot captures a blank screen instead of conversation content.
- [ ] With Block screenshots on, a screen recording (and QuickTime device
      mirroring) shows blank app content; the app-switcher preview is blank
      as well.
- [ ] Content presented over the root view — the QR code sheet, full-screen
      confirmation covers — is excluded from captures too.
- [ ] Turning the toggle off immediately restores normal screenshots without
      a relaunch, and the app keeps rendering and responding normally across
      several on/off flips.
- [ ] Sign-out of the last profile and reactivation from Settings → Profiles
      restores live foreground notifications (send a message from another
      device) and disappearing-message sweeps without relaunching.

## Per-chat notification controls & avatars

Run with a second device sending into a shared chat; native push enabled on
the test device.

- [ ] Chat details → Notifications shows All messages / Only mentions /
      Nothing; the chosen mode persists and the details row summarizes it
      (On / Mentions / Muted).
- [ ] "Only mentions": a plain message from the second device arrives
      silently (no banner/sound, lands in Notification Center); a message
      @-mentioning you banners normally.
- [ ] "Nothing" behaves like mute; the chat-list swipe Mute/Unmute stays in
      sync with the details picker.
- [ ] With local notifications OFF and native push ON, an incoming message
      produces no audible banner — the generic record lands quietly in
      Notification Center (#675). Currently expected to FAIL (audible generic
      banner): the engine discards suppressed records and reports the wake as
      an unattributable empty collection, which stays audible by design. Gated
      on mdk#888.
- [ ] Message notifications render the sender's avatar (or an initials
      monogram) via communication notifications, in both DMs and groups;
      group notifications keep the group name alongside the sender.
- [ ] A sender with no profile picture still notifies normally (monogram);
      a hostile/invalid picture URL never delays delivery.

## Notifications

- [ ] Settings → Notifications: enabling Local notifications prompts for
      system notification permission and persists the enabled state.
- [ ] Settings → Notifications: enabling Native push requests an APNS token,
      syncs a redacted token fingerprint, and does not expose the raw token.
- [ ] While device B is outside the app, sending a message from device A
      causes device B to receive a generic APNS wake that is rewritten by the
      Notification Service Extension into sender/message text.
- [ ] The app-icon badge increases to the locally computed unread total after
      that background push; the generic Transponder/APNS payload contains no
      account identifiers or unread count.
- [ ] Reading the message in-app, or using the notification's Mark as read
      action, decrements or clears the app-icon badge without requiring a
      relaunch.
- [ ] With two signed-in accounts, the app-icon badge reflects their combined
      unread total and foreground account switching does not reset it.
- [ ] Tapping that notification opens the matching chat for the matching
      account.
- [ ] With device B outside the app, have an admin remove B from a group,
      promote B to admin, and remove B's admin role in separate groups. Each
      change produces the matching local notification copy, opens the correct
      chat when tapped, and offers no Reply or Mark as read actions.
- [ ] Sending a message in a chat that device B is already viewing does not
      show a duplicate local banner while the app is foreground-active.
- [ ] A generic APNS wake with no local notification update shows a coherent
      generic fallback notification, not a blank title/body.
- [ ] Replying from the notification (long-press → Reply) while the app is
      fully backgrounded delivers the reply, marks the notified message read,
      and dismisses the conversation's notifications; reopening shows the
      reply in place. A failed reply surfaces the "Reply not sent" fallback.
- [ ] Marking read from the notification while backgrounded clears the
      conversation's notifications and unread badge. (Both action paths run on
      a short-lived frozen-cursor runtime that must not disturb the suspended
      app runtime — after the action, backgrounding stays clean and a later
      foreground resume still catches up normally.)

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
