# iOS design guidance

Use this guide for focused UI and UX improvements to White Noise.
[AGENTS.md](../AGENTS.md) remains authoritative for architecture, security,
localization, lifecycle, and validation. The user is the final visual and product
acceptance authority.

## Start with the existing app

- State the person's task and the visible outcome for one screen or bounded flow.
  Inspect its implementation, shared components, and open PRs before editing.
- Reuse [Components](../whitenoise-ios/Components), including `WNButton`,
  `WNInput`, and the shared section, icon, and photo controls. Follow
  [AppearanceTheme](../whitenoise-ios/Core/AppearanceTheme.swift) and the existing
  `appAppearance()` integration. Change shared styling deliberately, checking
  affected callers instead of adding a competing component or theme system.
- Preserve real loading, cancellation, validation, navigation, consent, and error
  paths. UI polish must preserve account operations, cryptography, persistence,
  and runtime behavior. Flag a design that needs new behavior separately.
- When a prototype reference is supplied, compare only the selected screen or
  flow and match it where production capabilities support it. Keep the prototype
  separate; do not require a personal checkout path or copy its mock state,
  platform assumptions, or different destructive-action semantics.
- Check the project's deployment targets, device families, and CI toolchain.
  Currently the app supports iOS 18 and iPhone/iPad, and CI uses Xcode 26.
  Preserve availability checks and older-system fallbacks for newer APIs and
  symbols; do not raise requirements as part of visual polish.

## Choose the native pattern

For a material platform choice, consult the current official Apple guidance and
the relevant [SwiftUI](https://developer.apple.com/documentation/swiftui/) or
[UIKit](https://developer.apple.com/documentation/uikit/) API documentation.
Include a supporting link and a short rationale in the PR when the choice needs
explanation. If custom UI is necessary, explain the gap and its accessibility
behavior there; a separate screen specification is unnecessary.

- Use native navigation for hierarchy, sheets for bounded tasks, menus for compact
  commands, and alerts for consequential interruptions. Preserve Back, dismissal,
  safe areas, keyboard avoidance, and focus behavior. See Apple's
  [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).
- Prefer `Form`, `List`, `Picker`, `Toggle`, and other standard controls when their
  semantics fit. Let system controls own their spacing, sizing, shape, material,
  and interaction; use existing app metrics for custom compositions. Avoid
  reconstructing platform chrome with arbitrary padding or fixed screen sizes.
  See [Layout](https://developer.apple.com/design/human-interface-guidelines/layout).
- Use semantic text styles and colors, with a clear reading and action hierarchy.
  Let text grow and wrap. Keep the established brand treatment while checking
  custom colors in light, dark, and increased-contrast appearances. See
  [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
  and [Color](https://developer.apple.com/design/human-interface-guidelines/color).
- Use familiar [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
  for interface actions, with appropriate scale, weight, and an accessible action
  name. Keep brand artwork distinct from interface symbols.
- Prefer system navigation, presentation, and control motion. Custom motion should
  explain a change or follow direct manipulation, remain interruptible, and respect
  Reduce Motion. Use haptics sparingly with visible feedback. See
  [Motion](https://developer.apple.com/design/human-interface-guidelines/motion).

## Write for the person using the app

Keep copy calm, direct, and useful, following Apple's
[Writing for interfaces](https://developer.apple.com/videos/play/wwdc2022/10037/).

- Lead with the task or outcome in familiar words. Keep established product terms
  consistent; avoid protocol jargon, marketing claims, blame, and false reassurance.
- Name actions precisely, such as **Sign In**, **Retry**, or **Open Settings**.
  Keep field labels available after typing; add hints only when they prevent errors.
- Put progress and validation near the initiating action. Explain an empty state
  and offer a useful next step when one exists. Do not announce success before the
  operation succeeds or repeat it when the resulting screen already explains it.
- Explain what could not be completed, a useful known reason, and an available
  recovery action. Check the existing [error catalog](error-catalog.md) and
  presentation helpers before changing error copy; do not expose new raw backend
  text or invent retry behavior.
- For destructive actions, name the exact loss, its scope, and recoverability.
  Preserve the production confirmation and cancellation requirements in AGENTS.md.
  Permission explanations must match the [active APIs](app-store-permissions.md).
- Use the existing string catalogs and localization helpers. Allow longer
  translations and right-to-left layouts; keep visible and spoken action names
  consistent. Use non-sensitive sample content in review captures.

## Review the running experience

- Check the applicable loading, disabled, empty, success, error, offline,
  permission, destructive, and recovery states with the existing production flow.
  A screenshot of the happy path does not verify the interaction.
- Inspect the current build at relevant iPhone and iPad sizes, in light and dark
  appearance, and at large and accessibility Dynamic Type sizes. Check clipping,
  contrast, keyboard/focus behavior, and whether primary actions remain reachable.
- Check VoiceOver labels, values, traits, grouping, order, and actions, plus Voice
  Control names where relevant. Aim for at least 44-by-44-point touch targets with
  adequate separation. Keep essential commands available beyond gestures, and
  convey state through more than color, sound, haptics, or motion alone. Follow
  [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
- Treat reproducible delayed feedback, blocked input, and visible hitches as
  usability defects. Follow the existing performance and async rules in AGENTS.md.
- Compare screenshots or recordings with the supplied reference in matching
  states. Identify a concrete cause and make a bounded change before checking
  again. Distinguish required corrections from usability improvements and optional
  polish; report evidence, user impact, and an observable expected result.
- Follow the existing validation guidance and relevant [manual tests](manual-tests.md).
  Include concise before/after evidence for visual changes and identify the build,
  device/OS, and states inspected. State what remains unverified, including any
  device or assistive-technology checks. A build or unit-test pass alone is not
  visual verification or product acceptance.
