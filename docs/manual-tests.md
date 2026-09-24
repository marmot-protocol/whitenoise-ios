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

## App Review demo environment

- [ ] Sign in or create a fresh reviewer profile, then open Settings →
      Developer Tools → Create Demo Environment. Confirm the disclosure and
      leave the app in the foreground while setup runs.
- [ ] Verify setup creates exactly one additional local profile named Johnny
      Appleseed, completes its KeyPackage publication, and returns to the
      original profile without showing the normal onboarding flow.
- [ ] Verify the app opens a direct conversation with Johnny containing real
      messages from both profiles, a reply from each profile, and reactions from
      both profiles. Switch profiles and confirm both sides can read the thread.
- [ ] Interrupt once after Johnny is created and once after the conversation is
      created. Reopen Developer Tools and Resume Demo Setup; it must reuse the
      same profile, conversation, messages, replies, and reactions rather than
      duplicating them.
- [ ] After completion, Open Demo Conversation returns to the original profile
      and opens the same thread. Clear Saved Demo Setup removes only the resume
      record; it must not delete either profile or published conversation data.

## Profile deletion

- [ ] With two profiles on the device, open Settings and verify **Delete Profile**
      is plainly visible immediately below **Sign Out**.
- [ ] Open **Sign Out** and confirm it keeps the profile and its local data on
      the device. Sign back in and verify the profile's chats are still present.
- [ ] Open **Delete Profile**, verify the disclosure names the local data and key
      material that will be destroyed and explains the limits of deleting copies
      held by members or independent relays. The destructive action must remain
      disabled until the displayed profile name is entered exactly.
- [ ] Delete one profile. Verify the app leaves its groups, removes its published
      KeyPackages where reachable, clears its local chats, drafts, media, settings,
      push registration, and device key material, then shows the remaining profile
      chooser. If no profile remains, verify the app returns to Welcome.
- [ ] Interrupt relay access during deletion and verify local removal still
      completes while the post-delete report identifies any relay-side work that
      could not be completed.

## Apple Pay donations

- [ ] With the runtime configuration endpoint unavailable, malformed, or returning
      the wrong Stripe mode/key prefix, open Settings → Donate. The form remains
      usable for reviewing amounts and disclosures, a temporary donation-unavailability
      message appears, and no donation website fallback is offered. A failed runtime
      configuration load offers Try Again; after restoring the endpoint, retry must
      enable payment without reopening Donate. Missing build configuration has no retry.
- [ ] Verify the heart and short nonprofit introduction keep system text margins.
      The larger frequency switcher, compact single-line preset cards, always-visible
      plain filled capsule Custom amount field with a US$ suffix, and native capsule Donate with Apple Pay button sit
      together inside one white grouped card. Presets have
      an empty circle and border; the selected preset has a checkmark and stronger
      border. Spacing between presets and the custom field is consistent, with a
      larger gap before the payment button. The input has no glass effect or
      persistent helper text; validation errors appear
      below it, aligned with the entered text and wrapping without truncation.
      Typing a third fractional digit must leave the amount and caret unchanged.
      Pasting an amount with extra decimals must preserve the previous text, show
      “Use up to two decimal places.”, and block payment until the input is corrected
      or a preset is selected. Test decimal comma, decimal point, localized digits,
      selection replacement, deletion, and pasted invalid text. Never round amounts. There is no
      selectable Custom row. Typing clears the preset selection; focusing alone does
      not. Choosing a preset clears the field. About your donation is a separate gray
      section below the button, with headline/body typography and a tight title-to-body
      gap. Monthly selection shows the billing helper below the cadence tabs,
      using centered footnote text, including when it wraps onto multiple lines. The
      management link appears only in the monthly-support card, never below the helper.
      Payment errors and availability messages use the same footnote styling and
      equal side insets as amount helpers. Verify long messages wrap within the
      button width at large text sizes.
      There is no extra Donate/Amount heading; the donation website link appears
      only in the lost-access recovery state.
- [ ] With no device donor credential, Donate shows no claimed subscription or
      payment history and does not look up a donor by email or White Noise identity.
      After a new Sandbox gift, verify the live screen loads Stripe-backed status
      on re-entry. If several monthly subscriptions exist, each gets its own card.
      Check active, cancellation scheduled, overdue/unpaid, incomplete, ended, and
      unknown states without treating a scheduled cancellation as already ended.
- [ ] In the example monthly supporter preview, verify the thank-you card appears
      above the donation controls. All three statuses use “Thank you for your support”
      as the title. Active copy includes the monthly amount; overdue copy asks the
      donor to check their payment method; scheduled cancellation explains that
      support is ending. Keep the title and body together, with a larger gap before
      footnote-sized payment details and the management link. Active shows the next
      payment date; scheduled cancellation shows its own known stop date; overdue
      shows no date. Never infer the stop date from the next payment date. The card
      remains available on either cadence tab. Check wrapping at large text sizes.
- [ ] With a saved donor credential, verify the card below the donation controls
      shows the newest three billing records, each marked One time or Monthly. See all
      billing activity opens the paged list, newest first. Pending, failed, credited,
      and manually paid invoices must not appear to be successful gifts. Only this list has
      tappable rows with chevrons; each opens an Invoice sheet with Share at the top
      right when a document is available. Test loading, pending, unavailable,
      retry, page-load failure, sharing, and closing back to the same list.
      No history card appears without records. Check accessibility text sizes.
      Real review data reloads from Stripe via the device's Keychain donor grant;
      no donor details, Stripe Customer ID, or payment history are stored in app defaults.
- [ ] Tapping Donate opens Apple Pay without inserting a Completing donation row.
      While Apple Pay configuration loads, show only a centered spinner inside
      the standard primary button, with no visible Loading label or separate row.
      Repeated taps stay disabled during payment; cancellation restores the button,
      and failures stay inline. Both successful one-time and monthly payments show
      a compact opaque thank-you sheet with a green checkmark, no invoice action,
      and a top-right Close button, with no Done button. Verify the monthly sheet
      says “Thank you for your commitment” and uses the monthly giving copy.
      Check that underlying content does not show through in light or dark mode,
      and verify Close and pull-down dismissal.
      Dismiss it, reopen an invoice through Payments, and return
      without dismissing Settings or showing the success sheet again.
- [ ] Focus Custom amount from different scroll positions. No Done toolbar appears.
      After the keyboard opens, the form aligns the payment button above it with
      standard bottom padding, keeping the custom field visible too. Repeat after
      dismissing and reopening the keyboard. Check again when an amount
      error appears, with a hardware keyboard, and after rotation. Dragging the form
      still dismisses the keyboard interactively.
- [ ] On iPhone and iPad, verify one-time/monthly selection, $10/$25/$50/$100
      presets, locale-specific decimal entry, the $1–$5,000 boundaries, keyboard
      dismissal, Dark Mode, all Dynamic Type sizes, and VoiceOver labels/values.
      Invalid and fractional-cent custom amounts must keep Apple Pay disabled.
- [ ] On a signed staging build, verify `/v1/apple-pay/config` returns `test` plus
      a `pk_test_` key and the signed app has the Apple merchant entitlement, then
      complete Apple Pay Sandbox authorization for a one-time gift.
      Confirm the backend receives integer cents, `one_time`, a fresh attempt ID,
      no donor object, the Stripe PaymentMethod ID, and a fresh 43-character
      donor-access nonce. Retrying the one bounded network request must retain
      the same attempt, nonce, and PaymentMethod IDs. A subsequent donation must
      send the Keychain donor token instead of a new nonce.
- [ ] Verify the donor credential is not saved when Apple Pay is canceled or fails,
      but is saved after confirmation succeeds. Reopen Donate to verify on-demand
      support/history reads, hosted document lookup, and history pagination. Return
      from Stripe management after canceling or updating a card and verify refresh.
      Test a revoked/expired grant: old history is not shown as an empty new-donor
      state, and a new gift does not silently merge with the old Stripe Customer.
      Verify the production flavor cannot use a staging credential.
- [ ] After a confirmed gift, refresh support while Stripe history is delayed and
      verify the new receipt remains available on that screen. Erase App Data and
      verify Donate no longer loads donor history in either flavor on that device.
- [ ] Verify a monthly gift requests only name and email, shows the amount as a
      monthly recurring payment, supplies the management URL, and completes with
      `monthly` plus donor contact. Missing name/email must be handled in Apple Pay,
      with no duplicate contact error below our button after dismissal. The form
      must allow retry without recording a successful payment.
      Confirm a new authorization uses a new attempt ID.
- [ ] Remove eligible Wallet cards and verify the native Set Up Apple Pay button
      opens Apple's Wallet setup. Return to the app after adding a supported card
      and verify the button refreshes to Donate with Apple Pay. On a device without
      Apple Pay (or where payments are restricted), verify a disabled flat gray capsule
      labeled Apple Pay unavailable appears, without glass, a border, a logo, or duplicate helper
      message. It must not open Wallet or a payment sheet. Verify Other ways to
      donate opens the IPF website when Apple Pay is unavailable or unconfigured.
- [ ] After payment succeeds, verify the thank-you sheet. From See all billing activity,
      open the payment's Invoice sheet. Receipt lookup starts only when the invoice
      is opened; a slow lookup must not delay the success sheet or keep Donate busy.
      The invoice starts with a loading indicator, without flashing an error.
      An available hosted receipt opens only on an approved Stripe HTTPS host;
      a pending or temporarily failed lookup offers Try Again and performs no
      automatic background polling. Dismissing a loading invoice must not mark it
      failed, and an older lookup must not replace a newer retry result.
      Sharing uses the service-provided document URL.
- [ ] Cancel a payment and start another. A late callback from the first attempt
      must not clear the newer attempt, show its error, or record a payment for it.
      Each success sheet must use that completed payment's cadence, even if the form
      selection changes afterward.
- [ ] Exercise a declined/cancelled payment, backend non-2xx response, malformed
      success response, timeout, and offline state. The UI must show only localized
      app-owned copy and never backend or Stripe error text.
- [ ] Before release, verify Stripe test-mode completion and hosted receipt,
      recurring renewal and portal cancellation, then one live payment. Finalize
      the tax/recurring copy with legal/accounting and repeat the App Store build
      on a signed physical device.

## MarmotKit 0.10.4 upgrade

- [ ] Back up the app's shared data before opening an existing installation with
      0.10.4. Migrations 87–89 are forward-only; do not run an older MDK against
      the upgraded store or remove migration records to attempt a downgrade.
- [ ] Send text, replies, voice notes and an album while relays are slow/offline.
      Each tap appears immediately once; local acceptance keeps the sending
      indicator until the timeline reports delivery. Resume/relaunch and verify
      retained submissions appear once, with newer composer typing intact.
- [ ] Interrupt a media send. Reopening must recover MDK's durable timeline;
      uncertain submissions must not offer a fresh upload as an automatic retry.
- [ ] Set Audio to Never: received voice notes and other audio both wait for a
      deliberate tap. Test independent image/video/document preferences too.
- [ ] Change Wi-Fi/cellular/Low Data Mode during automatic attachment acquisition,
      then background/resume and sign out/in. Old permission callbacks must not
      restart network work; a new runtime evaluates current settings afresh.
- [ ] Remove/cancel an attachment, evict presentation caches, and reopen the chat.
      Automatic loads must not reacquire it. Test an explicit Download again.
      Verify exhausted and completed-but-unretained transfers remain terminal
      until deliberate retry, including across relaunch.
- [ ] Open an album with removed or never-downloaded neighbouring images. Only
      selecting a page may request an explicit download; adjacent page creation
      must not fetch. Revisit ready pages offline and verify retained bytes work.
- [ ] Set Documents to Wi-Fi Only, then Never. Visible PDF/document bubbles
      automatically acquire only when permitted, without opening a share sheet.
      Removed/exhausted files stay unavailable until explicitly opened or retried.
- [ ] Pinch and double-tap fullscreen images to zoom, then pan in all directions.
      Panning while zoomed must neither change pages nor dismiss the viewer.
      Zoom back to fit, then verify paging, single-tap controls and swipe down to
      dismiss. Repeat on iPad, after rotation, with Reduce Motion and VoiceOver's
      adjustable zoom actions. Save/Share/Forward must still use original bytes.
- [ ] Leave Chats visible until its latest disappearing-message preview expires.
      Content and sender disappear without an incoming event; search no longer
      matches the preview. Repeat with the app backgrounded across expiry.
- [ ] On a signed staging build, repeat Native Push off/on after optimization,
      foreground/background receipt, and Notification Service Extension checks.

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
- [ ] Attention rows open native decision sheets; the underlying checklist keeps
      all rows and scroll position. No decisions expand between rows.
- [ ] Keep Save visible above the profile editor keyboard. A failed save retains
      entered text and image; successful saving dismisses the editor.
- [ ] Background/resume during the active attempt preserves its in-memory state.
      Force-quit/relaunch returns to Welcome, without restoring a setup screen or
      automatically opening Chats, including readiness reached before Open Chats.
- [ ] Close setup and explicitly sign in again: fresh checks run, and previously
      published profile/relay changes remain. There is no Later or Finish Setup.
- [ ] Cancel an approved unfinished publication with MDK 0.9.20. Host callbacks
      invalidate before cancellation, and cancellation finishes before another
      attempt begins. A failed cancellation stays retryable; never sign out,
      reuse the old checkpoint, or wipe to escape setup.
- [ ] Ready removes the checking subtitle/spinner, retains Skipped results, and
      enables the full-width Open Chats action. Required failures still gate entry.
- [ ] Verify large text, VoiceOver, Reduce Motion, Light and Dark appearances,
      long relay addresses, optional skipping, and failed discovery lookups.

## Device diagnostics and data removal

- [ ] Fresh app root: Welcome presents Help Improve White Noise before Sign In
      or Sign Up. Both sharing choices start off, work without a profile, and
      remain independent. The consent and account-entry sheets never overlap.
- [ ] The top-right checkmark (Done) without a usage grant saves a decline.
      A successful grant survives Done. Failed saves remain visibly unsaved with
      Retry; swipe dismissal cannot bypass persistence. Relaunch before signing
      in and verify no repeat after a saved decision. Add Profile preserves it.
- [ ] Upgrade an old analytics opt-in: sharing stays off until expanded consent
      is accepted after Chats/navigation are visible. Verify the explanation.
- [ ] Opt in before Sign Up/Sign In and inspect onboarding observations. Decline
      and verify no collection or later replay. Suspend while the sheet is open,
      resume, and verify it remains actionable without losing the saved choice.
- [ ] Privacy & Security → Diagnostics & Improvements controls the same runtime
      settings for every profile. Developer Tools never owns/gates either choice.
- [ ] Logging off retains local logs; Clear Diagnostic Logs clears every profile's
      logs without changing the preference. The runtime rotates active files.
- [ ] Developer Tools shows retained nonempty files even with logging off. Export
      Latest Audit Log opens the native Files picker with the most recently
      modified file's original `.jsonl` filename. Verify the export contains full
      JSON records, including context and event payloads, and no summary header.
- [ ] Tap an older audit segment to export that exact file. Compare its bytes
      with the source while recording is off. Cancel the picker and export again;
      the next export must use fresh data. Export while logging is active and
      around a rotation; verify complete JSONL records and no silent truncation.
- [ ] With MarmotKit 0.9.21 and logging enabled, export a newly recorded
      file: its name ends in `-v4.jsonl` (or a v4 segment suffix), records declare
      `marmot-forensics-audit/v4`, and source metadata contains system hardware
      model, platform, and app version without account/device names or labels.
      Logging remains off for users who have it disabled. On upgrade/startup,
      MDK removes legacy v1-v3 audit files and segments even with recording off;
      existing v4 files remain. The app implements no cleanup or filtering.
- [ ] Sign Out defaults Wipe Data From This Device on. Exact profile-name entry
      enables Sign Out in the same sheet; mismatched case/name stays disabled.
      Turning wiping off requires no typed confirmation and preserves local data.
- [ ] Sign-out failures retain the sheet. With surviving signed-in profiles, show
      their chooser; choosing one opens its Settings. Otherwise show Welcome.
      Relaunch at the chooser and select a profile: open Chats without reopening Settings.
- [ ] Erase App Data requires the displayed three-word phrase. Test with signed-in,
      signed-out and unfinished profiles; verify keys, chats, media, drafts,
      settings and diagnostics choices are removed, and the app returns to Welcome.
- [ ] Interrupt erasure or force an NSE root-lock collision: no concurrent root
      deletion occurs, incomplete erasure is reported, and Retry remains available.
      Retry keeps its progress/error sheet visible. Termination after normal preferences
      are cleared still offers recovery. Avatar loads cannot recreate caches during erasure.

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
- [ ] In a conversation with more than 100 messages, reopening at the bottom
      does not load older pages offscreen. Scroll to the top to load history,
      then back down through newer pages; both edges load again after leaving
      and returning. Images finishing layout keep the bottom pinned unless
      you have deliberately scrolled away to read older messages.
- [ ] Open a chat with unread history: the unread divider is aligned at the
      top. Open a fully-read chat: the latest-message sentinel is aligned at
      the bottom. Neither entry path flashes or later jumps to another anchor.

## Draft conflicts and send recovery

- [ ] With a conversation open, update its draft through another editor sharing
      the same MDK store. Editing the original composer must offer conflict
      resolution and preserve both drafts until a choice is made.
- [ ] Interrupt connectivity during a draft send. A later delivery error must
      not add a locally retryable duplicate beside the MDK message. Reopen the
      conversation: an unaccepted draft remains available; an accepted message
      stays in the timeline without restoring its submitted composer.

## Conversation keyboard avoidance

- [ ] Open a conversation at the latest message and tap the composer. The
      composer and bottom of the timeline stay above the keyboard; the final
      message remains visible without manually scrolling. Check this immediately
      after opening the chat, without first nudging the timeline to its bottom.
      The timeline moves smoothly with the keyboard instead of snapping; check Reduce Motion
      with the system keyboard transition as well.
- [ ] Open the attachment menu, dismiss it, and focus the composer again.
      Repeat with a multiline draft and while reading older messages. Keyboard
      presentation must preserve the reading position and leave no covered rows.
- [ ] Dismiss the keyboard interactively and reopen it. Check both portrait and
      landscape, and iPad with software and hardware keyboards.

## Conversation back navigation vs. swipe-to-reply

- [ ] Open a long-running agent conversation from Chats while its avatar is
      already visible. The avatar stays visible while the first timeline
      window loads, and the chat-list controls retain their normal navigation
      animation. Repeat with a short chat, Back, completed
      and cancelled swipe-back gestures, and search results on iPhone and iPad.
- [ ] Change the peer's avatar, then reopen the conversation. The new native
      projection wins; a removed avatar stays a placeholder. Switching profiles
      or erasing app data must not reuse another account's decoded avatar.

UIKit decides the final recognizer and keyboard ordering here, so these checks
have no XCTest UI coverage. Run them on a notched or Dynamic Island iPhone, on
both the iOS 18.0 deployment target and the newest installed iOS.

- [ ] Open a chat, tap the composer so the keyboard is up, then swipe back
      from the leading screen edge and complete the pop. The chat list
      appears with no keyboard, composer pane, or reply preview flashing
      behind or after the transition.
- [ ] Repeat with a reply already staged (swipe a message to reply, keep the
      preview visible): completing the edge pop returns to the chat list with
      no reply-preview or keyboard flash, and no message row animates as if
      swipe-to-reply had fired.
- [ ] Start the edge swipe over a message bubble and complete it. The row
      under the finger must not slide right or show the reply arrow.
- [ ] Type a draft, attach a photo, stage a reply, focus the composer, then
      start the edge swipe and release it back to cancel the pop. You stay in
      the chat with the same draft text, the same attachment, the same reply
      target, and the keyboard back up.
- [ ] Cancel an edge swipe with the keyboard **down**: you stay in the chat
      and the keyboard stays down. No reply target appears.
- [ ] Swipe a message to reply starting well away from the leading edge
      (mid-bubble): the reply preview appears and the keyboard comes up once.
- [ ] Tap the header back chevron with the keyboard up: same result as the
      completed edge swipe — no keyboard or reply UI behind the pop.

## Chat-list search

Chats is the root of its navigation stack, so a search surface without a
visible exit cannot be escaped except by force-quitting. The bar is app-drawn
on every version, because `SearchFieldPlacement` has no bottom option before
iOS 26 and UIKit takes over the navigation bar when a native field activates.

- [ ] In each scope (Chats, Unread, Archived, Left), tap **Search**: a search
      bar rises from the **bottom** with the keyboard, carrying the field and
      an **✕** beside it. The magnifier leaves the trailing toolbar; Profile,
      Filter and New Message stay put. Repeat with an empty list and with a
      query that matches nothing.
- [ ] No navigation-bar drawer and no **Cancel** word on either version.
- [ ] On iOS 26 the field pill and the ✕ are Liquid Glass: chat rows are
      visible refracting through them, both react to touch, and they read as
      one piece of glass rather than two separately sampled ones. On iOS 18
      they are the material capsule and the filled 44pt circle.
- [ ] Scroll the list while search is open: content passes under the glass
      without a hard edge or a second fade appearing.
- [ ] Tap the **✕**: the keyboard drops, the query clears, the bar goes away,
      and the magnifier is back with the scope unfiltered.
- [ ] Type a query, then tap the field's **⊗** clear button: the query empties,
      the bar stays up, and the field keeps focus.
- [ ] Swipe the list to dismiss the keyboard: the bar and its ✕ stay visible
      and still work. Tap the field to bring the keyboard back.
- [ ] Search, tap a result: the conversation opens; on **Back**, search is
      closed and the ordinary toolbar is showing.
- [ ] Search, then change scope from the Filter menu: the bar stays up and the
      query filters the newly selected scope.
- [ ] Enter selection mode while search is active: the selection bar takes the
      bottom inset and the search bar does not stack underneath it.
- [ ] Search, background the app, foreground it: the bar is still up and the ✕
      still exits. Force-quit and relaunch: search is closed.
- [ ] Search, then switch profiles from Settings: the new profile's list is
      unfiltered with search closed.
- [ ] Tap **Search** again while it is already open: the typed query and the
      keyboard survive.
- [ ] With VoiceOver on and Dynamic Type at an accessibility size, the ✕ reads
      out as **Close search**, is reachable, and keeps a 44pt target.
- [ ] In the Unread scope with unread chats, **Read All** and the search bar
      do not overlap or clip each other.

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

- [ ] From Group Info, open another member's profile. Message, New Group,
      and Add to Group retain the three-button row and use matching neutral
      colors in light/dark mode, including accessibility text sizes.
- [ ] Add to Group opens even before group loading completes. Verify the
      loading indicator, retryable load error, and explanatory empty state.
      Eligible groups require admin membership and must not already contain
      the person. After adding them, reopening the picker excludes that group.

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

- [ ] Compare public profiles from New Chat search, Chat Info → About, group
      members, blocked users, and QR/profile links with the prototype: one-third
      width avatar, name, centered bio card, verified address and compact npub,
      then grouped Groups in Common/Add to Group, Follow/Unfollow, and Block.
      Message is a full-width primary action below, omitted in Chat Info → About.
      Nickname is editable in the action card; when set, the header also shows
      the published profile name. The own-profile edit form stays unchanged.
      No banner, Create Group, website, or Lightning address appears.
- [ ] Groups in Common shows overlapping avatars and opens a separate group list
      with names/member counts and Add to Another Group. Direct-message chats do
      not appear here. Invite a peer and verify the shared/available lists refresh.
      Add to Group remains a separate action with zero or many groups in common,
      while loading, and after a failed lookup. Its picker explains empty/error
      states and only offers eligible groups.
- [ ] On first profile/Chat Info load, the groups row shows progress until the
      result is known; a failed lookup offers Retry. Refresh or background and
      foreground the same profile: Groups in Common keeps its previous result
      while loading. Switch account or peer: the previous result is cleared.
- [ ] Chat Info stays separate: shared identity header, About/Mute/Disappearing/
      Search controls, grouped relationship actions, Shared in Chat category links,
      and Chat Actions. Mute's menu retains Notifications. Verify categories,
      archive, leave confirmations, and group moderation still operate normally.
- [ ] Review on iPhone and iPad in light/dark and large Dynamic Type: no clipping,
      readable names/bio, copyable npub, and reachable actions. Check VoiceOver
      order, action names, verified-address badge, and copy confirmation.
- [ ] Follow/unfollow a person from each entry and from Chat Info. The action reflects
      the saved follow relationship after reopening; failed loads offer Retry and
      failed publishes retain the previous state. Other accounts stored on this
      device still show the Follow and Block rows, disabled under the current
      eligibility rules. Developer integration must enable these cases only after
      resolving that policy; UI visibility must not imply a successful mutation.
- [ ] From a fresh account with no published follow list, try Follow and
      reopen the profile to verify persistence. If MDK returns
      `FollowListUnavailable`, the alert explains that the relay follow list is
      unavailable and suggests checking connection/relay settings; the previous
      relationship remains unchanged. Escalate a persistent fresh-account failure
      to MDK integration rather than treating the UI error copy as a backend fix.
- [ ] A blocked peer retains the full action card: group/follow rows are disabled,
      Unblock remains available, and Message stays hidden until unblocked.
- [ ] Switch accounts or suspend/resume while follow state is loading or saving;
      an old completion must not change the new account's displayed relationship.
- [ ] Leave and reopen a profile while its Nostr address is being verified; a
      cancelled lookup retries. Removing/changing the address or switching the
      target account never restores a stale verified badge.
      Repeat in direct Chat Info, including scrolling its identity section offscreen.
- [ ] Switch accounts during an invitation, group lookup, Message action, or
      Block confirmation. Old work must not navigate, announce success, or act
      on the replacement account. Invitation failures remain visible even if
      the eligible-group list becomes empty.
- [ ] Set, edit, and clear a nickname from public profiles and direct Chat Info.
      Chat titles, search, mentions, profiles, and sender-revealing notifications
      use the active account's private nickname; clearing restores the profile
      name. Generic notifications still hide the sender. Switch accounts while
      editing: the old draft must not be saved under the replacement account.
      Existing saved nicknames remain available. Blocked-peer actions remain gated.

- [ ] Settings → AI Agents shows the introduction, Hermes, OpenClaw, OpenCode,
      Codex, and manual setup. Expand/collapse each prompt and copy it; pasted
      text matches the preview and contains the active profile's public npub.
      The selected connector's title and subtitle stay fixed while the prompt
      opens below them. The npub copy control has no pill background.
- [ ] Switch profiles and reopen AI Agents: prompts and Copy npub use the newly
      selected profile. The documentation link opens the MDK connector guide.
- [ ] Check AI Agents in light/dark appearance and large Dynamic Type. Long
      prompts remain readable and selectable, and VoiceOver identifies each
      connector's show/hide and copy buttons. Manual setup refers to New Chat.

- [ ] Settings → account row → **Edit**: filling in display name + about and
      tapping **Done** shows a success toast. There is no **More** section and
      no picture/banner URL fields; an existing banner survives the republish.
- [ ] In that editor, **Add Photo**/**Change Photo** opens the same menu as Sign
      Up (Photos, Files, Find Image on Web, and Remove Photo once one is set).
      Photos and Files show the public-avatar alert first, then the crop editor;
      the avatar updates after the upload and **Done** publishes it.
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
- [ ] Settings → Sign Out uses the single confirmation sheet. Wiping removes
      the profile and local keys; retaining data keeps them available for sign-in.
      Remaining signed-in profiles go to the chooser; otherwise show Welcome.
- [ ] Group Details → Set/Edit group image rejects non-HTTPS, localhost,
      private-address, and invalid URLs; a public HTTPS image URL previews
      and saves.
- [ ] Group Details → Set/Edit group image → Search the web shows the
      DuckDuckGo/image-host disclosure, returns selectable results, and
      saves the selected public HTTPS result.

## Privacy, audit, and telemetry

- [ ] First-launch consent follows the checks above. Existing saved choices
      survive profile switches; scope changes require fresh explicit acceptance.
- [ ] Settings → Privacy & Security → Diagnostics & Improvements: **Share usage
      and diagnostics** persists without restarting the runtime. Saved consent
      is separate from each exporter's current readiness.
- [ ] **Share Diagnostic Logs** creates local files after activity. Turning it off
      retains files; **Clear Diagnostic Logs** clears them independently.
- [ ] Switch profiles and background/relaunch: both diagnostics choices remain
      device-wide. Enable/disable each independently without restarting the runtime.
- [ ] With configured credentials and logging enabled, verify sealed log segments
      reach Goggles after MDK's batching window. Toggle off and verify subsequent
      automatic upload passes stop; local preference tests do not prove ingestion.
- [ ] Verify production/staging OTLP tenant routing and separate Aptabase
      applications. Audit uploads retain their separate shared token. Inspect
      persisted synthetic staging events, not just HTTP success; never copy keys.
- [ ] Verify operator/retention disclosure against the deployment and run
      `scripts/check-analytics-release-config.py <built-app/Info.plist>` for each
      flavor. The development fallback text is not a distribution-ready policy.
- [ ] Rapid background/foreground with a stalled collector still releases storage.
      Frozen notification runtimes emit no analytics. Revocation clears queued
      observations; re-enabling rotates diagnostic identity. See
      `docs/usage-diagnostics-integration.md` for rollout gates.
- [ ] Settings → Developer Tools: Developer mode reveals Streaming debug and
      **Open Diagnostics**. Disabling it leaves both diagnostics preferences intact.
- [ ] With Developer mode on, Group Details → Export Conversation
      Transcript opens the share sheet for a JSON file; dismissing the
      share sheet removes the temporary export file.

## Concurrent group changes

- [ ] With MarmotKit 0.9.19, exercise concurrent group updates from two members.
      A superseded change that MDK reissues needs no banner. Other outcomes show
      **Review group changes** without requiring Developer Tools to be open.
      Check invitation/removal guidance and the current chat membership before retrying.
- [ ] Background and foreground during recovery: the event observer follows the
      current runtime. Signed-out profiles and events from a released runtime
      must not show notices. Diagnostics includes the change kind and recovery outcome.

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

## Screen privacy

- [ ] Enable **Hide Screen in App Switcher** in Privacy & Security. Background
      the app from a conversation, a QR sheet, and a full-screen cover: the app
      switcher shows only the privacy cover. Returning restores the same content.
- [ ] With the setting on, start screen recording or mirroring: once iOS reports
      capture, the cover hides the content on both the device and the recording.
      Stop capture and confirm content returns without relaunching.
- [ ] Ordinary screenshots remain possible, as the settings footer explains.
- [ ] With the setting off, recording and the app-switcher preview work normally
      unless the separate app-lock setting requires its own shield.
- [ ] Repeat with app lock on/off, authentication prompts, rotation, large text,
      VoiceOver, and iPad windows. The cover never steals keyboard focus and does
      not expose a sheet while transitioning to the background.
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
- [ ] On an optimized device build, turn Native push off and back on. Both
      operations complete without a cancellation error, registration returns,
      and the enabled setting survives leaving Settings and relaunching the app.
- [ ] Settings → Notifications → Preview starts on Generic on a fresh install
      and on upgrade, and the example row matches the selected option.
- [ ] With Preview set to Sender and Message, a message from device A while
      device B is outside the app produces a generic APNS wake that the
      Notification Service Extension rewrites into sender/message text.
- [ ] With Preview set to Sender Only, the same notification names the sender
      (avatar still rendered) and its body says only that an encrypted message
      arrived — on the Lock Screen, in the banner, and in Notification Center.
- [ ] With Preview set to Generic, that notification reads
      "White Noise / New encrypted message" with no sender name or avatar, and
      an offline backlog delivers only generic extra notifications.
- [ ] Turning Local Notifications off disables the Preview options; the
      selection survives the app being force-quit and relaunched.
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
- [ ] A failed Create/Invite shows the operation title and readable error details
      in toasts and inline messages, without `MarmotKitError.Runtime(details: ...)`
      wrappers. The selection stays available for retry. Expanded diagnostics
      also omit the wrapper and redact private-key-shaped input.

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

## Developer Key Packages

- With a single current package, Developer Tools → Key Packages shows its identifier, published time, size, and Publish New Key Package. No relay list or maintenance block appears.
- When a different package for this profile is found on relays, Other Key Packages on Relays appears below the current-package controls, with publication details and sanitized relay addresses. Include an older package still owned locally; local-only retained packages should remain hidden.
- Relay echoes of the current key material must not create additional rows, even when the publication event differs. A newer relay timestamp must not change which package is shown as current.
- Publish New Key Package refreshes the current row after success. An error remains actionable; a missing lifecycle or failed read must not promote an arbitrary relay package to current.
- Swipe-delete remains available for additional relay packages. Refresh and switch profiles; neither action should show another profile's packages.


## MDK 0.9.20 recovery and presentation

- On disposable upgraded profiles, verify cached DM names/avatars remain stable
  offline; profile/title changes update, while unread, pin, and archive changes
  appear even with the same presentation revision. Switch profiles during a
  pending list subscription and rapidly background/resume; no old rows return.
- Simulate a recovered group branch. Review the authenticated inviter before
  confirming rejoin; saved history remains. Decline removes only the selected
  offer. Change local group state while confirmation is open: the stale approval
  fails and requires a newly reviewed offer. Advisory sync failure must not
  disable sending or change membership. Pending re-invites retry without host
  publication; exhausted ones direct the user to invite again.
- Use disposable corrupt/exhausted onboarding checkpoints. Sign In exposes an
  explicit recovery action, explains latest-only evidence/sign-out, and requires
  entering the private key again. Verify an old revision/epoch cannot approve a
  fresh attempt. Cancel while approved publication is pending and begin again.
- Under consent, send text/media and receive a new message in a visible chat.
  Diagnostics should show host message-visible timings only after layout. Loading
  history, duplicate visibility callbacks, and work started before consent must
  not add samples. Revoke sharing or switch profiles before layout; late samples
  must be dropped. Confirm backend transport timings are not duplicated by iOS.

## Host preparation timings

- [ ] After upgrading from an empty custom registry, existing usage grants require
      renewed consent. Declining leaves both built-in usage and custom timing
      observations disabled; diagnostic-log consent stays independent.
- [ ] Exercise inbox, timeline, composer parsing, and camera/library preparation.
      Verify staging aggregates use the registered stage names with bucketed
      elapsed/outcome properties and MDK's aggregation metadata.
- [ ] Exercise successful, failed, cancelled, and partially accepted media batches.
      Empty selection creates no preparation observation.
- [ ] Revoke consent or switch profiles while preparation is running; old work
      produces no observation. Confirm timings do not replace visible-frame
      milestones or imply relay acceptance/recipient delivery.

## Permission and App Store submission checks

Follow [app-store-permissions.md](app-store-permissions.md) for localized system
prompts, signed-archive validation, native SDK privacy manifests, export
classification, and the privacy-policy/disclosure checks before distribution.

## MDK master projections and developer reset

Local adoption checkpoint: `dcb3c1c3772ab52187b92932382019231188c814` (matching
locally generated Swift and binary). A published matching pin is required before
committing/shipping the binding update.

- [ ] Browse an account with more than 200 chats. Page forward and backward;
      the visible row keeps its pixel position when earlier rows are discarded.
      Receive a message that reorders a row and remove/archive the visible anchor.
      Verify retained/recovered anchors, pull-to-refresh, and Return to newest chats.
- [ ] Switch Chats, Unread, Archived, and Left; queued departures and active
      disbands appear in Left. Search finds chats beyond the loaded window.
      Pin reordering includes the entire pin set, and forwarding and Mark all read
      include chats outside the current window. Local nicknames remain visible.
- [ ] Account/app badges count unread messages plus one per manual-only reminder.
      Pending invitations retain their invitation row indicator and add no badge
      count. Check an inactive account, temporary read unavailability, sign-out,
      and repeated background/foreground cycles.
- [ ] View a message/reply containing accepted and rejected attachment siblings.
      Keep the caption and accepted attachments; show an inert unsupported/unreadable
      placeholder at each rejected slot. Downloads and gallery navigation still work.
- [ ] Developer mode → group info → Chat Developer Tools → Delete Local Group.
      Cancel preserves the group. Confirm on a broken active group stops its work,
      removes local history/state and downloaded media caches, and closes the chat.
      Other members are unaffected. An old invitation cannot restore it; a fresh
      invitation created after reset can. Verify a failed reset keeps the group,
      restores the composer/draft, and displays an error.

### MarmotKit 0.10.0 conversation, drafts, and blocking

Use staging and fresh test storage for migration 75; do not downgrade an upgraded
Marmot root. Automated simulator checks do not replace these device checks.

- [ ] Open an accepted chat with unread messages: position at the prepared first
      unread row. Open a notification/reply target: position at that message; an
      unavailable target shows feedback without an endless history-loading loop.
- [ ] Scroll both directions through more than 200 mixed message rows while new
      messages arrive. Retained/recovered anchors preserve the visible position;
      the latest-message button returns directly to the tail. Repeat at 50 and
      200 retained rows and record replacement/layout timings on a physical device.
- [ ] Send identical short messages rapidly, including text sent earlier in the
      chat. Each send retains its bubble through confirmation; an old message
      never acknowledges a new send. Repeat with slow delivery and media.
- [ ] At the bottom of a full 200-row window, stop scrolling, receive another
      message, then send. New rows stay live without leaving and reopening.
      Reading history preserves position; the latest button and sending restore
      tail following. Repeat with the keyboard visible and during deceleration.
- [ ] Simulate slow paging while messages arrive. A rejected revision can retry
      while the edge remains visible; a timed-out admitted page must not advance
      twice. Verify search/reply jumps and first-unread opening separately.
- [ ] Search the retained conversation and continue into older history. Matches
      removed from the window disappear. Back/foreground/account changes retire
      the old receive loop; late results must not change the new screen.
- [ ] Opening and paging alone do not mark offscreen messages read. Visible-message
      acknowledgements update Unread, profile counts, and the application badge.
      Pending invitations contribute exactly once. Check muted, archived, left,
      and blocked cases with both foreground and NSE notification presentation.
- [ ] Type a second draft during a slow send. After acceptance only the sent
      revision disappears; the newer draft survives reopening and relaunching.
      Repeat with media, failed sends, backgrounding, and two editing sessions.
      A conflict preserves local text; both “Keep my draft” and “Use saved draft”
      resolve explicitly. Missing attachment bytes show a load error.
- [ ] Block/unblock from a profile or direct-chat info, then inspect Privacy &
      Security → Blocked Users. Confirmed changes update both screens. An uncertain
      publication offers the same operation again and never claims success.
      Blocking hides the author's messages and prevents direct sending while
      preserving group participation and stored history. Verify cross-device
      delivery and notification behavior with a second test identity.
- [ ] Reactions show the full count and your selected state even when your identity
      is outside the preview. Overflow/truncated reactor previews are disclosed.
- [ ] Developer Key Packages shows current and superseded relay events.
- [ ] Welcome displays the agreement beneath Sign Up/Sign In. The Terms of Service
      link opens https://whitenoise.chat/terms. Check large text and VoiceOver.

- [ ] In a blocked direct chat, the composer explains “You blocked this user” and
      offers View Profile. Follow it to the profile, unblock via Block or Unblock
      User, and return: the notice disappears and sending resumes once MDK confirms
      availability. An unavailable unblocked chat must not claim the peer is blocked.

## MarmotKit 0.10.1 reporting and avatar adoption

- [ ] With two upgraded devices in a group, a non-admin can long-press their own
      or another member's message and choose **Report**. Check the reason picker,
      optional explanation, encrypted-group disclosure, send failure and pending
      delivery feedback. The full actions menu must remain scrollable/reachable
      on a small iPhone and with accessibility text sizes.
- [ ] A reported message shows the report symbol beside its timestamp. All group
      members can open Message Info to see its reports, reporter, report date,
      reason, optional explanation, and dismissed status. Verify live updates,
      pagination, and that changing accounts clears the previous report list.
- [ ] Moderation cards separate report date/reporter from message sender/sent
      time, reuse the message bubble and avatar, and offer side-by-side Dismiss
      and Delete buttons. Check long explanations, media, deleted/unavailable
      targets, large text, dark mode, and VoiceOver on iPhone and iPad.
- [ ] Only active admins see **Group Info → Moderation**. Reports on older or
      personally blocked senders' messages appear using the current message
      projection. New reports and other admins' decisions refresh the panel.
- [ ] **Dismiss Report** removes only that report from the open review list and
      preserves the message, its attachments, and other reports on the message.
      **Delete Message** confirms the destructive action and removes the target
      content on upgraded peers. An unreported message can also be deleted by an
      admin from its long-press menu. A demoted admin cannot submit either action.
- [ ] With relays unavailable, accepted moderation remains visibly pending and
      cannot be repeatedly submitted from the panel. Reconnection applies the
      actual MDK projection; no report or dismissal creates an ordinary chat row,
      unread increment, or chat notification. Older peers may retain content.
- [ ] Scroll chat lists and conversations, open group/contact info and reaction
      details, then reopen offline: MDK-provided avatars remain available. Change
      an avatar on another device and check refresh without a title, unread,
      scroll-position, or pending-message jump. Pending invitations must not load
      remote avatars. Switch profiles and suspend/resume during acquisition;
      another profile's pixels must never appear.
- [ ] Validate the in-place staging upgrade on a physical device with existing
      accounts and groups. MDK 0.10.1 advances account storage migrations; a
      subsequent downgrade is unsupported. No reset or re-import is part of the
      normal upgrade.

## Native pending message ownership

- [ ] Send text and replies with slow relays, including identical consecutive
      messages. Each accepted message appears once under its MDK ID, progresses
      from pending to sent, and never collapses a second local bubble.
- [ ] Send media and verify the native attachment projection takes over after
      upload. Before MDK admission there is no fabricated pending timeline row.
- [ ] Force a definite pre-admission failure: the failed local attempt remains
      available for retry/discard. An uncertain completion must not offer a retry
      that could duplicate a committed message.

## Profile sharing menu

- On your profile QR screen, open Share: both Share Profile URL and Share Profile Picture are available. URL sharing preserves the existing profile link.
- Share Profile Picture with and without an avatar, with a long name, and in light/dark appearance. The exported card includes the White Noise logo, current name/avatar, and a clear QR code. Save/send the image and scan it on another device to open the same profile.
- Check the menu and share sheet on iPhone and iPad, including large text and VoiceOver. Cancel the sheet and share again.
- With an uncached avatar offline, picture sharing shows a recoverable error; URL sharing remains available. Navigating away or changing profiles during preparation must not present a stale share sheet.

## Reading unread history across pages

- Open a conversation with more than 100 unread messages at its unread marker. Scroll down across multiple newer-page spinners, pause at each boundary, and verify the same message stays at the same screen offset when the page loads, including the final page.
- While still reading history, receive a message or let media expand. Neither should jump to the end or mark unseen messages read. At the actual conversation end, new messages should follow normally.
- Confirm that sending a message and tapping the down arrow still reach the latest message. Check both slow paging and a quick page completion after you lift your finger.

## MarmotKit 0.10.2 attachments and diagnostics

- [ ] Upgrade an existing staging installation without erasing it. Verify long
      conversations, drafts, reactions, unread positioning, avatars and notifications.
      Database migrations 81–86 make downgrading unsupported; use a pre-upgrade
      backup/export for rollback, never an older binary against migrated storage.
- [ ] Open Shared Media in a long conversation. Each request reads at most 100
      original slots. Load more across sparse categories and rejected attachments;
      no false final empty state, duplicated item, fabricated total or reordered album.
      New additions offer Refresh; deletion/blocking/expiry removes stale pages.
      Switch account and suspend/resume while a page is loading.
- [ ] Receive attachments, then reopen offline. Verified retained bytes load without
      another HTTP download. Test zero-byte files and an interrupted/resumed transfer.
      Message info shows current-attempt progress and Cancel download, Remove download,
      and Download again. Cancel/removal survives navigation and restart; automatic
      thumbnails do not undo it. Reply previews use the original attachment's identity.
- [ ] Set different automatic-download preferences for photos, audio, video and files.
      Check Wi-Fi, cellular, constrained, offline and network transitions. MDK's
      background gate is enabled only when all categories are allowed; selective
      visible loads retain the existing downloader until MDK has a per-category API.
      Pending invitations must never start automatic attachment acquisition.
- [ ] In Data Usage → Download Storage, save quota/reserve/size limits, reload and
      check persistence for each profile. Full storage pauses new work without evicting
      existing retained files. These MDK limits do not replace the temporary legacy
      display cache's limits. Check save failure and account switching during saving.
- [ ] Compare author and admin deletions in the timeline, replies, chat previews,
      moderation and transcript export. Historical unknown provenance stays generic.
- [ ] Key Packages shows locally available inventory before relay refresh. Pull to
      refresh merges relay observations without calling them owned by this device.
- [ ] With diagnostics consent enabled, open a populated, empty, unavailable and slow
      conversation. Developer diagnostics include runtime counters and conversation
      visible/composer-ready outcomes. Revoking consent invalidates pending host timings.
- [ ] Review the new download screens on iPhone/iPad, large text, light/dark appearance
      and VoiceOver. Check translations and button reachability.

## Conversation-open telemetry boundaries

- Start is the navigation intent in `AppState.presentChat` or a chat-list tap,
  before asynchronous row lookup and dismissal retries. Retries of that navigation
  retain one attempt; the unavailable screen's explicit Retry starts a new one.
- The UI boundary is SwiftUI's geometry callback after content is laid out and
  initial timeline positioning settles. This is a layout approximation, not proof
  of an exact frame reaching the display. A loaded empty view counts as local content.
- Composer timing waits for an epoch-backed authoritative header. Temporary local
  placeholders, recoverable subscription errors and syncing do not terminate it.
  An empty draft does not prevent readiness. There is no telemetry-only deadline;
  the existing destination-resolution timeout reports Timeout. Leaving/replacing
  the destination or suspending the runtime cancels unfinished milestones. Resume
  does not restart an attempt without another user navigation action.
- Device-wide diagnostics consent still gates every sample. Account-context rotation
  holds at most two completed samples until consent is rechecked; an explicit consent
  change discards them. An intent begun without an enabled recorder is not exported
  retroactively when consent/export becomes available (including cold-start routing).
- Host reports are completed-only, not live gauges. Runtime counters retain their
  own in-flight/age semantics. Debug output includes runtime histogram buckets.
- Inbound visibility includes only appended rows at an already loaded live tail;
  historical pages and replaced windows are excluded. Outbound timing still starts
  at Send. If a native pending row rendered before its returned message ID can be
  correlated, the existing host code drops that sample rather than using SDK
  completion as render time. Full outbound coverage requires earlier correlation.
- [ ] On device, compare a cold/slow open, empty chat, restricted chat, deep link,
      notification (including another profile), rapid Back/open, and background/resume.
      Check both host series and runtime series at the OTLP collector, grouped by
      iOS and exact app version/build. Collector delivery and physical display timing
      are not established by the automated tests.

## MarmotKit 0.10.3 prepared chat rows

- Verify text, attachment-only, mixed, whitespace-only, and reply-only drafts in
  Chats. Clear/send a draft, receive a message while drafting, and return from
  the composer: the preview should follow MDK without changing unread counts,
  pins, or chat order. Exact composer text must survive a shortened list preview.
- Page away from a draft and back; switch profiles and background/foreground.
  Confirm previews remain scoped to the current account/window and retain the
  scroll anchor. Invitations with a message preview must keep their invite badge.
- Check row gestures in active, archived, Left, and pending-departure views.
  Leave still uses admin preflight; local deletion still asks for confirmation;
  restoring departed history must not rejoin it. Mute/unmute follows this device's
  notification mode, including timed mute expiry.
- Search public profiles (for example `jack` and `jeffg`) on a real device and
  check offline/error behavior. Optional relay AUTH is handled by the native
  0.10.3 release; genuinely auth-required relays are not guaranteed accessible.
- Signed-device checks and App Store archive acceptance remain separate from
  automated simulator tests and unsigned release/privacy validation.

## Foreground notification batching

- With Chats or another conversation open, deliver 15 new messages to one chat
  within two seconds. Expect one banner/sound and one Notification Center entry.
  The deadline starts at the first message, rather than moving with each arrival.
- Deliver a later burst: it should replace that chat's previous foreground entry.
  Another chat or signed-in account must have its own independent batch.
- Verify a single-message preview, a multi-message count, sender-only previews,
  and generic mode (no sender, content, or count). Invites/admin notices remain
  immediate. Unread badges remain MDK-owned.
- Open/read the receiving chat, mute it, or disable notifications during the
  window; no foreground alert should bypass the existing delivery-time checks.
  Sign out during the window: its pending batch should be cancelled.
- Background during the window: the already-scheduled local request should still
  deliver once. This change does not batch subsequent APNS/NSE notifications.
- Use Reply/Mark Read on a batch and confirm the latest represented message is
  targeted. An older action must not remove a newer unread batch.

## Capped composer scrolling

- Type or paste more than four lines. The composer should stop growing at its
  existing height limit, scroll internally, and keep the insertion point visible.
- Drag within the long draft to read earlier lines; it must stay where you scroll
  until typing or moving the insertion point requires a caret reveal.
- Delete back to one line and clear/send the draft. The composer should shrink,
  reset its scroll offset, and preserve the full text when sending.
