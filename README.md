# OpenClawWidgetKitPrototype

A minimal native macOS app + WidgetKit extension prototype generated from the command line.

Build check:

```sh
xcodebuild -project OpenClawWidgetKitPrototype.xcodeproj -target OpenClawWidgetKitPrototype -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Open in Xcode to run/sign/install the containing app, then add **OpenClaw Widget** from the macOS widget gallery.

## Shareable configuration

The shareable input is one JSON file, `openclaw-widget.json`, in the App Group
container (`group.local.openclaw.WidgetKitPrototype`). The app, Widget and
embedded worker resolve the same shared container. Do not assume its physical
`Library/Group Containers` path: ask the worker for the active locations:

```sh
Sub2APIRefreshWorker --print-config-path
Sub2APIRefreshWorker --print-data-directory
```

Start from
[`config.example.json`](config.example.json), replace the example endpoints,
account IDs and local tokens with values for your own backend, then set file
permissions to `600`:

```sh
data_dir="$(Sub2APIRefreshWorker --print-data-directory)"
mkdir -p "$data_dir"
cp config.example.json "$data_dir/openclaw-widget.json"
chmod 600 "$data_dir/openclaw-widget.json"
```

Before signing, set your Apple Developer Team and register the exact App Group
identifier in the app, Widget extension, and helper provisioning profiles. The
placeholder group above is for source builds only; a signed distribution must
use your Team-approved group. When App Group access is unavailable, new builds
write to the isolated per-user fallback `~/.config/openclaw-widgetkitprototype`;
cross-process sharing is not guaranteed in that mode. The old
`~/.config/openclaw` path is retained only as a compatibility read for the
legacy installed app and is never the new build's write target.

`schemaVersion: 1` groups `backend`, optional `bridge`, `accounts`, optional
`clickup`, `widget`, and optional `behavior`. ClickUp is omitted by default and
is not required for quota refresh. The config contains endpoints and secrets;
the cache, status, logs, lock, and ClickUp outbox remain separate files.
`behavior.refreshIntervalSeconds` controls the Widget timeline and is bounded
to a minimum of 60 seconds.

The worker also accepts `--config /path/to/file.json` to select credentials for
a standalone run; runtime cache/status/log/lock files still stay in the shared
runtime directory so the App and Widget remain aligned. The external config's
parent directory is never used for runtime state. Without that option it uses the new file,
then the old `sub2api-balance.json` name. Legacy flat JSON
fields (`adminBaseURL`, `adminToken`, `bridgeBaseURL`, `bridgeToken`, and
`widgetURL`) are decoded by the same model, so an existing setup can be copied
without rewriting it. The old absolute path is only an explicit compatibility
fallback when no portable or App Group config exists. A newly signed sandboxed
App/Widget should use only the App Group; legacy absolute-path reads are for
the old installed bundle or an unsandboxed worker, which migrates cache output
into the shared directory on its next run.

This sharing change only modifies source/config documentation. It does not
replace, stop, start, sign, or re-register any already installed app or
LaunchAgent.

The installed app includes `Sub2APIRefreshWorker`. Install its per-user, one-minute background schedule after replacing the app:

```sh
./scripts/install-refresh-launch-agent.sh
```

The app's **恢复账号状态** button runs `Sub2APIRefreshWorker --restore-status`, which calls Sub2API's `clear-rate-limit` for configured accounts and then refreshes the cached quota data. During a normal refresh, if quota is detected as recovered while Sub2API still marks an account as rate-limited, the worker clears that rate-limit state automatically.

The backend contract is **Sub2API-compatible**, not an arbitrary REST adapter:
the worker uses fixed `/api/v1/admin/...` routes, including paginated admin
account lookup, quota, account availability, and `clear-rate-limit` endpoints.
Set `backend.adminBaseURL` to the origin of a compatible service. If it is
missing or invalid, admin-backed refresh, account lookup, restore, quota, and
Sub2API status paths fail before making a network request; legacy accounts with
their own `baseURL`/`apiKey` can still use their direct usage endpoint.

Runtime diagnostics are written beside the config in the shared App Group
`Config` directory (or the documented per-user/legacy fallback):

- `sub2api-refresh-status.json`
- `sub2api-refresh-worker.log`
- `sub2api-refresh-launchd.err.log`
- `sub2api-clickup-outbox.json`
- `sub2api-clickup-receipts.json`
- `sub2api-clickup-test-result.json`

The shared configuration contains endpoint credentials and other secrets; it
is not a redacted-only file. Keep it mode `600`, avoid distributing real tokens, and
prefer moving secrets to Keychain or another OS-protected store for a signed
distribution.

Offline configuration validation (no network and no real user configuration):

```sh
./scripts/validate-config.sh
```
