# Config Agent Notes

Xcode flavor settings for production and staging. Local secrets live in
`TelemetrySecrets.xcconfig` (gitignored). Copy
`TelemetrySecrets.xcconfig.example` and do not commit real tokens.

`Shared.xcconfig` holds values that are the same for every flavor.
`Production.xcconfig` and `Staging.xcconfig` override only the settings that
must differ.

## Shared by every flavor

These stay the same for production, staging, Debug, and Release:

- **Audit-log endpoint** — compiled into MarmotKit. Do not add a per-flavor
  audit URL in xcconfig.
- **Audit-log bearer token** — one `AUDIT_LOG_TOKEN_WHITENOISE_IOS` value
  becomes `WHITENOISE_AUDIT_LOG_BEARER_TOKEN` for every scheme.
- **OTLP endpoint** — `WHITENOISE_OTLP_ENDPOINT` is the same collector for
  every flavor (`https://otlp.ipf.dev/v1/metrics`).
- **Native-push relay hint** — `WHITENOISE_PUSH_RELAY_HINT` is shared because
  production and staging currently use the same relays. Split it only if the
  flavors start using different relays.

## Flavor-specific

- **OTLP bearer token** — production uses
  `PRODUCTION_OTLP_TOKEN_WHITENOISE_IOS`; staging uses
  `STAGING_OTLP_TOKEN_WHITENOISE_IOS`. Each token already encodes the tenant.
  Do not add a separate tenant name, extra OTLP resource field, or
  flavor-specific collector URL to distinguish tenants. Pick the matching
  flavor token.
  Preserve the existing `tenant: "whitenoise-ios"` resource metadata and
  `deploymentEnvironment` value; token selection controls collector routing.
- **Native-push server pubkey** — `WHITENOISE_PUSH_SERVER_PUBKEY_HEX` differs
  between production and staging. Do not share or swap those keys.

## Rules

- Do not reuse an OTLP token for Goggles audit-log uploads. The audit tracker
  and the metrics collector are different services.
- Do not invent a second audit token or audit endpoint per flavor.
- Do not split the OTLP endpoint by flavor.
- Keep the push relay hint shared unless the relays themselves diverge.
- Keep the push server pubkey flavor-specific.

## Product analytics

Aptabase uses separate production/staging application keys. Set the full verified
`APTABASE_EVENTS_ENDPOINT_WHITENOISE_IOS` and verified human-readable
`APTABASE_RETENTION_WHITENOISE_IOS`; neither an app key nor a backend URL grants consent.
`WHITENOISE_PRODUCT_ANALYTICS_OPERATOR` is a stable lowercase MDK consent-scope
label; changing the operator or destination origin requires acceptance again.
Product metadata uses marketing version and iOS major version, with phone/tablet
class only. Keep it separate from the richer OTLP resource. Do not ship a build
with unverified retention or unresolved Aptabase settings; use the release preflight.
