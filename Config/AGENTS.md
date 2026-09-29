# Config Agent Notes

Xcode flavor settings for production and staging. Local secrets live in
`TelemetrySecrets.xcconfig` (gitignored). Copy
`TelemetrySecrets.xcconfig.example` and do not commit real tokens.

`Shared.xcconfig` holds values that are the same for every flavor.
`Production.xcconfig` and `Staging.xcconfig` override only the settings that
must differ.

## Shared by every flavor

These stay the same for production, staging, Debug, and Release:

- **Audit v5 endpoint** — `WHITENOISE_AUDIT_OTLP_ENDPOINT` is the audit
  receiver's OTLP logs route (`https://otlp.whitenoise.chat/v1/logs`) for every
  flavor.
- **Audit write token** — one `AUDIT_LOG_TOKEN_WHITENOISE_IOS` value (the
  receiver's audit write token) becomes `WHITENOISE_AUDIT_LOG_BEARER_TOKEN` for
  every scheme.
- **OTLP metrics endpoint** — `WHITENOISE_OTLP_ENDPOINT` is the same collector
  for every flavor (`https://otlp.whitenoise.chat/v1/metrics`).
- **OTLP metrics token** — one `OTLP_TOKEN_WHITENOISE_IOS` value becomes
  `WHITENOISE_OTLP_BEARER_TOKEN` for every scheme. The flavor is reported
  through the `deploymentEnvironment` resource attribute, not the token.
- **Native-push relay hint** — `WHITENOISE_PUSH_RELAY_HINT` is shared because
  production and staging currently use the same relays. Split it only if the
  flavors start using different relays.

## Flavor-specific

- **Native-push server pubkey** — `WHITENOISE_PUSH_SERVER_PUBKEY_HEX` differs
  between production and staging. Do not share or swap those keys.

## Rules

- Do not reuse the metrics OTLP token for audit delivery, or the audit token
  for metrics. The two write tokens are not interchangeable.
- Do not invent a second audit token or audit endpoint per flavor.
- Do not split the OTLP endpoint by flavor.
- Keep the push relay hint shared unless the relays themselves diverge.
- Keep the push server pubkey flavor-specific.
- Audit delivery is v5 only, through `setAuditOtlpConfigV5` with the fixed
  `TelemetryBuildConfig.auditOtlpDestination`; keep that identity stable across
  token rotation because MDK's delivery cursor is bound to it. The v4 whole-file
  tracker is not configured. A rejected audit config must not block runtime
  startup. Recording stays the user's opt-in setting. MDK owns schema
  eligibility and legacy-log cleanup; the app exports original files without
  migrating or filtering their contents.

## Product analytics

Aptabase uses separate production/staging application keys. Set the full verified
`APTABASE_EVENTS_ENDPOINT_WHITENOISE_IOS` and verified human-readable
`APTABASE_RETENTION_WHITENOISE_IOS`; neither an app key nor a backend URL grants consent.
`WHITENOISE_PRODUCT_ANALYTICS_OPERATOR` is a stable lowercase MDK consent-scope
label; changing the operator or destination origin requires acceptance again.
Product metadata uses marketing version and iOS major version, with phone/tablet
class only. Keep it separate from the richer OTLP resource. Do not ship a build
with unverified retention or unresolved Aptabase settings; use the release preflight.
