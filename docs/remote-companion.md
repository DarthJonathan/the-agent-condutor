# Remote companion

The SwiftUI app and web companion use the same local Rust engine. A Go relay, based on expense_tracker's controller/service/PostgreSQL layout, authenticates users and devices and routes HTTPS requests. The Mac initiates all network connections. The relay never invokes a coding CLI.

## Implementation order

1. Go API, isolated PostgreSQL tables, revocable cookie sessions, CSRF, paired device credentials, ownership checks, bounded command/event storage.
2. SvelteKit web interface: login, devices/workspaces, live chat, mentions, questions/approvals, cancellation and offline history.
3. Rust background host: private local socket, one engine owner, outbound HTTPS polling, incremental events, durable command receipts.
4. Mac Remote screen: login, explicit folder sharing, device credential in Keychain, start-at-login service, disconnect/revoke.
5. Docker Compose, optional HTTPS gateway, cross-user and reconnect tests, real engine/web smoke tests, native build.

## What the backend stores

| Record | Purpose | Retention |
| --- | --- | --- |
| Users and hashed browser-session verifiers | Login, expiry and server-side logout | Sessions expire after 12 hours; at most 20 logins per account |
| Devices and hashed device-token verifiers | Pairing, heartbeat, revocation | Until revoked/deleted |
| Shared workspace IDs and labels | Scope remote commands; paths remain on the Mac | Until sharing is removed |
| Latest session snapshots and lightweight previews | Recent chats, coworkers, mailbox, questions, approvals, changed-file/diff/check summaries | At most 100 sessions per device; removed on unsharing or revocation |
| Sequenced event patches | Stream/replay without retransmitting entire replies | Recent 256 events per device, at most 7 days; snapshot recovery if cursor expires |
| Commands and receipts | Delivery, expiry, acknowledgement, deduplication | Recent 1,000 commands per device / 7 days; 60-second delivery expiry |
| Audit metadata | Who requested an action and its delivery outcome | Bounded; no credentials |

Local provider credentials, executable configuration, environment variables, CLI session credential files and whole repositories are not uploaded. Chat/diff content is visible to the relay operator: this first version uses TLS, not end-to-end encryption. Sharing is opt-in per folder. Use an encrypted database volume and protected backups in hosted deployment.

Remote history is a bounded copy: recent 32 messages plus pending forms where space permits, up to 96 KiB per response, 20 file diffs and 16 check results. Larger histories show an explicit notice to use the complete transcript on the Mac. The dashboard loads small previews for all sessions, then streams full content for the selected chat. There is no separate unrestricted shell-command API; remote approvals reference an existing pending request on the Mac.

## Protocol and trust

- Browser: same-origin HttpOnly cookie; CSRF header and Origin check on mutations; SSE for events, JSON POST for commands. No tokens in browser storage or URLs.
- Native login: same account API, then authenticated device enrollment with the folders chosen on the Mac. Device token is returned once and stored in Keychain.
- Device: separate bearer credential, scoped to its own owner/device. It advertises opaque workspace IDs. A browser cannot grant access to an arbitrary filesystem path.
- Every command carries a UUID, workspace ID and expiry. The relay rejects offline devices, unauthorized IDs and expired commands. The Mac validates scope again using its own folder map and local settings.
- Command acknowledgements mean delivery to the engine, not successful completion of the agent's task. Ambiguous crash recovery must report uncertainty rather than silently execute twice.
- SSE IDs are database sequence IDs. Retained patches plus latest snapshots restore a disconnected browser. In-progress text is sent as append patches, with snapshots for recovery.
- Removing folder sharing purges its remote snapshots and commands. Device revocation purges mirrored chats, rejects polling/uploads and closes authorized streams on their next auth check. Command outcome metadata remains until retention cleanup.
- Development permits HTTP only for explicit loopback origins. Public deployment requires HTTPS and a non-default session secret. There is no production default password.

## Runtime

The local host owns one `--bridge` child and serves private newline-delimited JSON over a user-only Unix socket. SwiftUI attaches using `--connect`; closing its window detaches the UI. Remote sharing keeps the host alive. A user LaunchAgent can restart it at login; the machine must still be awake, signed in, online, and able to use its provider credentials.

Tests use temporary data directories and databases; never the expense_tracker database or a real coding-provider account.

## Local setup

```sh
bash scripts/remote-dev.sh
```

The script generates private, unique database and session secrets in the ignored `.env` file when it is absent. It starts the separate Conductor database, Go API and SvelteKit app. Existing environment files and database volumes are preserved. Open **http://localhost:3005**, create a development account, then reopen the updated Mac app and choose **Remote**. Enter the same server URL and account, select folders, and sign in. Optional start at login keeps the host available after the desktop window closes.

Both PostgreSQL and the Go API are internal Docker services. Only the web server binds to `127.0.0.1:3005`. A local HTTP test is not yet access from outside the home network.

## HTTPS hosting

Run Compose on an always available server. Set the following in its private `.env`, keeping fresh `POSTGRES_PASSWORD` and `SESSION_SECRET` values:

```dotenv
PUBLIC_ORIGIN=https://conductor.example.com
CONDUCTOR_DOMAIN=conductor.example.com
DEVELOPMENT=false
ALLOW_SIGNUP=false
WEB_PORT=3005
```

Point the domain at the server and allow inbound 80/443. Start the HTTPS gateway with:

```sh
docker compose --profile https up -d --build
```

Caddy terminates TLS and forwards streaming HTTP to the web app. Alternatively, use an existing TLS reverse proxy on the same host against `127.0.0.1:3005`; preserve streaming responses and the configured public origin. Do not publish the database or backend container ports. This project uses its own `conductor_*` tables and volume; it does not share expense_tracker's database or deployment.

Production has no open signup or default account. Provision an account without placing its password in argv or committing it:

```sh
read -r CONDUCTOR_USER_EMAIL
read -r -s CONDUCTOR_USER_PASSWORD
export CONDUCTOR_USER_EMAIL CONDUCTOR_USER_PASSWORD
docker compose run --rm -e CONDUCTOR_USER_EMAIL -e CONDUCTOR_USER_PASSWORD backend --create-user
unset CONDUCTOR_USER_EMAIL CONDUCTOR_USER_PASSWORD
```

Use a password with 12–72 bytes. Then sign in to that HTTPS address from both the Mac app and browser. The Mac opens outbound connections only; no laptop port forwarding is needed. Current authentication is password based; SSO/MFA and end-to-end encryption are later work. Login does not wake a sleeping or powered off laptop.

## Verification

```sh
docker compose --profile test run --rm --build backend-test
docker compose --profile test build backend-audit
cd frontend && npm ci && npm test && npm run check && npm run build
cd ..
cargo build --locked
python3 scripts/remote-smoke.py
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path target/swift-module-cache macos/Models.swift macos/NativeResponseText.swift macos/MentionEditor.swift macos/RemoteAccess.swift macos/EngineStore.swift macos/Views.swift scripts/remote-store-smoke.swift -o target/remote-store-smoke-test
target/remote-store-smoke-test
```

Go tests create and drop their own PostgreSQL schema. The end-to-end fixture verifies the Svelte HTTP proxy, append events, engine acknowledgements, native session continuation, duplicate IDs, restart, user questions, approvals, cancellation and revocation with a fake CLI. The Docker build uses a pinned patched Go toolchain; vulnerability checks inspect that runtime rather than an older Go installation on the Mac.

`scripts/remote-web-smoke.mjs` exercises the actual web interface using a disposable account, simulated device and headless Playwright browser. It verifies tables, sanitization, @ autocomplete, model/effort controls, multi-select answers, streaming updates, logout and mobile width, then saves screenshots under `target/remote-web/`. Set `CONDUCTOR_PLAYWRIGHT_MODULES` to a directory containing an installed Playwright package and, if needed, `CONDUCTOR_CHROMIUM_EXECUTABLE` to an existing compatible headless Chromium executable before running it with Node. It does not use provider accounts or desktop data.
