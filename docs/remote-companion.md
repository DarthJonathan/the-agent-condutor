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

## Installable web app and offline access

The frontend includes a web app manifest, app icons and a SvelteKit service worker. Visit the hosted HTTPS website once while online to install the public app shell and assets. Use **Install app** in a supported browser, or Safari’s **Share → Add to Home Screen** on iPhone/iPad. Localhost also works for development; a production build is required to test service-worker caching.

The shell loads without a connection after its first successful cache installation. By default, no account or chat data is persisted. Enable **Save chats offline** on a trusted browser/device to retain previously opened conversations, rendered Markdown, coworkers and change summaries. Copies are limited to three recently visited computers, twenty chats per computer, five MiB total and seven days. Conversations that were never opened may have only a title/preview; full histories still live on the Mac. Browser storage may be evicted by the operating system.

An **Offline · read-only** banner identifies cached content and its save time. Messages, questions, approvals, configuration changes and cancellation require a live connection; commands are never queued for later execution. Reconnection checks the server session before restoring live access. A rejected session, a different account, sign-out or computer disconnection clears the local copy. **Clear offline copy** removes it immediately; server sign-out requires a connection. Removed sharing is reconciled when the browser next connects.

The service worker caches only public HTML/assets, never `/api/` responses, SSE or mutation requests. Offline chat copies use IndexedDB and contain account ID/email and bounded content, without passwords, CSRF tokens, session cookies or provider credentials. They are readable by someone with access to this browser profile and are not end-to-end encrypted. The server continues to enforce ownership and cookie/CSRF protection for every online request.

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

### Published GHCR images

`.github/workflows/remote-containers.yml` runs backend tests with PostgreSQL and the Go race detector, frontend protocol and type checks, and validation of the development and GHCR Compose configurations. Pull requests also build both Dockerfiles without registry credentials. After checks pass, pushes to `main`, `v*` tags and manual runs on `main` or a version tag publish both Linux AMD64 and ARM64 images:

- `ghcr.io/darthjonathan/the-agent-condutor-backend`
- `ghcr.io/darthjonathan/the-agent-condutor-frontend`

Names follow the lowercase GitHub repository, so forks use their own namespace. The workflow uses the [built-in `GITHUB_TOKEN` with `packages: write`](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images), SHA-pinned official actions, component-specific build caches, SBOMs and BuildKit provenance. No personal access token is needed for the publishing workflow. The first run requires these files and both application folders to be committed and pushed; local changes do not publish anything.

Main builds receive `main`, `latest` and `sha-<full-commit>` tags. A version tag such as `v0.2.1` receives `0.2.1`, `0.2` and its SHA tag; version tags do not move `latest`. Choose the same version or commit tag for both services. Published digests appear in each workflow job's summary.

To use these images on the HTTPS server, keep the hosted settings above and add the following to that server's private `.env`:

```dotenv
COMPOSE_FILE=docker-compose.yml:deploy/compose.ghcr.yml
CONDUCTOR_IMAGE_PREFIX=ghcr.io/darthjonathan/the-agent-condutor
CONDUCTOR_IMAGE_TAG=sha-REPLACE_WITH_THE_PUBLISHED_FULL_COMMIT
```

The Compose override removes frontend/backend build definitions, requires an explicit published tag, and forces production mode. Public signup is disabled by default and follows `ALLOW_SIGNUP` from the server's environment. Use a current Docker Compose version with [`!reset` support](https://docs.docker.com/reference/compose-file/merge/#reset-value). Keep the repository's Compose and Caddy files on the server; the application source is not compiled there.

New [GHCR packages are private by default](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#pushing-container-images). For private images, authenticate on the server using a GitHub personal access token (classic) with `read:packages` and permission to those packages; use `docker login ghcr.io --username YOUR_GITHUB_USER --password-stdin`. Public packages can be pulled without login. Do not place this token in Compose, image build arguments or the repository. GitHub package settings control visibility and repository access.

Deploy or update the selected image tag:

```sh
docker compose --profile https pull
docker compose --profile https up -d --no-build
```

The `COMPOSE_FILE` setting also makes the account-provisioning command below use the published backend image. Changing `CONDUCTOR_IMAGE_TAG` to an earlier published version and running these commands again rolls back the application containers; PostgreSQL data remains in its volume. This workflow publishes containers to GHCR; it does not connect to or restart a hosted server automatically.

### Production registration

Production signup is an explicit opt-in, independent of development mode. To let users create their own accounts, set these values in the server's private `.env`:

```dotenv
PUBLIC_ORIGIN=https://your.domain
DEVELOPMENT=false
ALLOW_SIGNUP=true
```

After deploying an image containing this change, recreate the backend with `docker compose up -d --no-build backend`. The website reads `GET /api/v1/auth/options` and shows **Create an account** when `signup_enabled` is true. Reload an already open login page after changing the setting.

Registration uses `POST /api/v1/auth/register` with JSON containing `email` and `password`; a password must contain 12–72 bytes. Successful registration signs the user in with the same secure session cookie and CSRF protection as login. HTTPS, session-secret validation, password hashing and signup rate limits remain enforced. Only the new account's paired devices and shared chats are accessible to it.

Set `ALLOW_SIGNUP=false` (or omit it) to disable registration; the endpoint returns HTTP 403 and the signup button is hidden. Existing accounts can still sign in. Owner-created accounts remain available whether signup is enabled or disabled. There is no default account. Provision one without placing its password in argv or committing it:

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

For the signup UI specifically, build the frontend and run `node scripts/signup-web-smoke.mjs`. This starts an isolated frontend on an ephemeral loopback port and supplies controlled API responses, without creating accounts or touching the running app. It checks enabled/disabled signup, form errors and retry, pending-state controls, automatic sign-in and return to sign-in after logout, and saves `target/remote-web/signup.png`. Real production registration, hashed passwords, session cookies and CSRF checks are covered separately by the backend integration tests.

For the PWA, build the frontend and run `node scripts/pwa-web-smoke.mjs` using the same Playwright environment variables. Its disposable HTTP relay and fresh headless browser exercise the actual service worker, installation metadata/icon sizes, offline reloads, opt-in chat copies, read-only questions/approvals, reconnection, account changes, expired sessions, sign-out and clearing. It does not access provider accounts or the running app, and saves `target/remote-web/pwa-offline.png`.

The signup and PWA fixtures require the pinned Playwright Chromium, installed with `frontend/node_modules/.bin/playwright install chromium`; an explicit `CONDUCTOR_CHROMIUM_EXECUTABLE` override is available for debugging. They do not silently substitute the system Chrome. PWA recovery checks use **Reconnect** when an emulated online event arrives before transport is ready, then require enabled sign-in/chat controls; offline, ownership and clearing assertions remain enforced.
