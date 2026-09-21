# Changelog

All notable changes to the SEHC AI Gateway are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/); this project uses
semantic-ish versioning.

## [1.7.10] — 2026-09-21

### Fixed
- **Wizard now sets generous service timeouts** on new models
  (`connect 60s / read 600s / write 600s`), matching the Models tab's Register.
  Previously Wizard-created services used Kong's 60s default read timeout, which
  caused **504s** on slow models (e.g. Whisper audio transcription of long files).

### Added
- **Warning when adding Request Size Limit** to a model: it now confirms first,
  noting the 10 MB default rejects audio / file-upload models (e.g. Whisper
  `/v1/audio/transcriptions`) with 413. Cancel leaves the model untouched.

## [1.7.9] — 2026-09-21

### Added
- **"Both" key style** in *Create API key* (Consumers). Picking *Both —
  x-api-key + Authorization Bearer* issues two key-auth credentials from one
  secret (`<secret>` and `Bearer <secret>`) in one click, so the same project
  authenticates for OpenAI-compatible clients (`Authorization: Bearer`) and
  generic clients (`x-api-key`). Set the model's key-auth `key_names` to both
  headers to match. (Verified end-to-end against Kong: both headers pass, no
  key is rejected.)

## [1.7.8] — 2026-09-21

### Added
- **Tags in the Topology map.** Each service card now shows its tags with an
  **✎ tags** inline editor, and every route chip shows its tags with a 🏷
  editor (and a tags tooltip). Editing PATCHes the object's `tags`; blank
  clears them — same semantics as the Models/Routes tabs. (Models and Routes
  tabs already showed and edited tags since 1.7.2; only Topology was missing.)

## [1.7.7] — 2026-09-21

### Security
- **Fixed a stored-XSS gap**: `esc()` now also escapes single quotes and
  backticks (not just `& < > "`). Values interpolated into `onclick` handlers
  inside single-quoted args (consumer usernames, key values, etc.) can no
  longer break out and run script in the admin session.

### Fixed
- **Wizard no longer wipes tags or stacks duplicate keys** when run against an
  existing project. It now preserves the consumer's existing tags, reuses an
  existing API key instead of creating a second one, and adds an ACL group /
  ip-restriction only if not already present (idempotent re-runs). A token is
  required only when creating a *brand-new* project (`New model` mode).
- **Editing a model to add a route** now creates it with `strip_path:true`,
  matching Register (was `false`, which silently broke OpenAI-style `/v1` paths).
- **`pca-deploy.sh` no longer prints a false green "Checksum OK"** after a
  checksum mismatch or when verification was skipped (the unconditional line
  after the check is removed).

### Changed
- **Usage dated ranges now warn on truncation**: if the selected window starts
  before the oldest line in the retained request log, the tab shows a "range
  starts before the retained log — totals are a lower bound" note instead of
  silently under-reporting.

### Removed
- **Deleted the orphaned Projects tab** (unreachable — no nav item) and its
  handlers/markup/listener; its correct tag-preserve logic was ported into the
  Wizard first (see Fixed). Also removed two stale duplicate `portal.html`
  files (`nginx/portal.html`, `offline-package/nginx/portal.html`) and the dead
  `nginx/portal.html` bind-mount in docker-compose — only `portal/portal.html`
  is served now.

## [1.7.6] — 2026-09-19

### Added
- **Key style selector when creating a consumer API key.** The *Create API key*
  form (Consumers tab) gains a **Key style** dropdown — *Authorization: Bearer
  (OpenAI-compatible)* (default) or *x-api-key (n8n / generic)*. OpenAI style
  stores the credential as `Bearer <key>` so it matches an `Authorization`
  header (auto-generating the token first when the key is left blank, and never
  double-prefixing an existing `Bearer …`); x-api-key stores the raw key (or
  lets Kong auto-generate). Matches the header convention already used by the
  Wizard, so keys work against the model's key-auth without hand-editing.

## [1.7.5] — 2026-09-17

### Added
- **Consumer and model filters on the Usage tab.** Two dropdowns (**All
  consumers / All models** by default) narrow the table to one consumer, one
  model, or both — client-side, no reload. Options are rebuilt from the current
  period's data and the pick is preserved across refreshes; stats, grouped and
  flat views, and the CSV export all respect the active filter. An
  *(unauthenticated)* entry filters anonymous traffic when *Authenticated only*
  is off.

## [1.7.4] — 2026-09-17

### Added
- **Custom date range on the Usage tab.** The Period selector gains a
  **Custom…** option that reveals two date pickers (from → to, end day
  inclusive); usage for that window is aggregated from the request log, same
  as the presets. Defaults both dates to today when opened.

### Changed
- Usage tab subtitle no longer says "(Prometheus)" — the source now depends on
  the selected period (Prometheus for All-time, request log for dated ranges),
  which the per-view hint states explicitly.

## [1.7.3] — 2026-09-17

### Added
- **Time period selector on the Usage tab** — *All-time · Today · Yesterday ·
  Last 7 days.* All-time keeps the live Prometheus counters (cumulative since
  Kong restart). The dated ranges are computed from the gateway request log
  (per-request `started_at` + request/response sizes), so requests, 5xx and
  bandwidth are attributed per consumer × model within the chosen day window.
  The hint line notes which source is in use; dated ranges cover the retained
  request log (~10 MB rolling).

## [1.7.2] — 2026-09-17

### Added
- **Tag management on Models, Routes and Consumers.** Every list now shows the
  Kong tags on each object, and the edit panel has a **Tags** field
  (comma-separated) to add, change or remove them:
  - **Models** — edit box gained a Tags field (`PATCH /services` now sends
    `tags`); the Tags column already existed.
  - **Routes** — new **Tags** column in the table plus a Tags field in the edit
    box (`PATCH /routes` now sends `tags`).
  - **Consumers** — already supported (unchanged).
  Clearing the field and saving removes all tags.

## [1.7.1] — 2026-09-16

### Changed
- **Redesigned the Wizard to be mode-first.** The tab now opens on a landing
  screen with three intent cards — **New model** (service + route + key-auth +
  acl + first project), **New project** (add a project to a model that already
  exists), and **Grant access** (give a new project one or more existing ACL
  groups) — instead of a single long form. Picking a card reveals only the
  fields that mode needs; **← Change type** returns to the landing. Same
  underlying create logic (`wCreate`), fewer irrelevant fields on screen.
  (Replaces the previous step/review wizard.)

## [1.7.0] — 2026-09-16

### Changed
- **Redesigned the Plugins tab into two columns.** **Active on this model** (left)
  lists every plugin currently applied — icon, friendly + raw name, config
  summary, status, and Edit / On-Off / delete — with the config editor inline.
  **Add protection** (right) shows the curated plugins not yet active
  (key-auth, acl, ip-restriction, rate-limiting, request-size-limiting,
  bot-detection, cors) as one-click **Add** with sensible defaults, plus an
  *any Kong plugin* picker. Clearer active-vs-available split; new plugins are
  auto-named. (Replaces the old stacked toggle list.)

## [1.6.1] — 2026-09-16

### Changed
- **Type-ahead instead of pick-by-eye** on the ACL and Consumers pickers. The
  *Add member* (consumer / group), *Allow group on service* (group / service),
  and the Consumers *Add to ACL group* and *Create key* consumer/group fields are
  now typeable inputs with an autocomplete suggestion list (`<datalist>`): start
  typing to filter, and you can still enter a brand-new group name.

## [1.6.0] — 2026-09-16

### Added
- **Access-denied diagnostics in the Requests tab.** Quick filters for
  **Denied (4xx)** and **Errors (5xx)**, a **Path** column, and a **"Why blocked"**
  hint per row: 401 → key-auth (missing/invalid key); 403 → ACL **or**
  ip-restriction (compare the **Source IP** with the consumer's Allowed IPs);
  5xx → upstream unreachable. Blocked rows are tinted, and the Source IP shown is
  what Kong actually sees — the fix for the common "IP not allowed" case where a
  Docker/NAT address is whitelisted instead of the client's LAN IP.

### Deploy
```bash
tar xzf kong-pca-bundle-v1.6.0.tar.gz && cd v1.6.0
sudo ./pca-deploy.sh kong-pca-bundle-v1.6.0.tar.gz --cert-ip <PCA_IP>
```

## [1.5.3] — 2026-09-15

### Fixed
- **Deploy no longer silently deploys the wrong thing.** `pca-deploy.sh` now
  accepts **either** the inner `kong-deploy-*.tar.gz` **or** the outer
  `kong-pca-bundle-*.tar.gz` — if the outer bundle is passed it transparently
  switches to the nested deploy tarball. Previously passing the bundle by
  mistake extracted one layer too shallow and left the install unchanged (it
  reported "Upgrade complete" but kept the old version).

### Changed
- **SHA256 verification is now optional** for this air-gapped internal deploy —
  it verifies only when a checksum file sits next to the tarball, and a missing
  or mismatched checksum warns instead of aborting.

## [1.5.2] — 2026-09-15

### Changed
- **Default API-key header is now `Authorization: Bearer` (OpenAI-compatible).**
  The header selector in Register Model and both Wizard modes now defaults to the
  OpenAI standard instead of `x-api-key`; `x-api-key` (n8n / generic) is still
  available as the second option. Keys created for the Authorization style are
  stored with the `Bearer ` prefix, as before.

## [1.5.1] — 2026-09-15

### Changed
- **Removed the standalone "Users" link** from the Kong Manager nav bar and the
  Audit Log top bar, now that user management lives in the portal's Users tab —
  one path instead of two. The standalone `/users/` page still works if reached
  directly.

## [1.5.0] — 2026-09-15

### Added
- **Users tab in the portal.** User management (previously the standalone
  `/users/` page) is now a **Users** tab inside the Model Portal: add / delete
  users, promote / demote role, reset password, set email, toggle per-user MFA,
  and edit **SMTP** settings with a test-send. It calls the usermgmt app under
  `/users/api` with the same session (admin-only); the standalone page still
  works too.

### QA
- Full smoke pass across all **15 tabs** on a live gateway: every tab renders
  real data with **no JS errors** and nothing stuck loading.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.5.0.sha256.txt
tar xzf kong-pca-bundle-v1.5.0.tar.gz && cd v1.5.0
sudo ./pca-deploy.sh kong-deploy-v1.5.0.tar.gz --cert-ip <PCA_IP>
```

## [1.4.2] — 2026-09-15

### Changed
- **Portal UI is English by default.** Converted the strings that had crept in as
  Vietnamese back to English: plugin type labels (`API Key`, `ACL (authorization)`,
  `IP Restriction`, `Rate Limit`, …) and descriptions, the Auto-name dialog and
  toasts, the Test-tab status hints, and a couple of tooltips. No behaviour change.

## [1.4.1] — 2026-09-15

### Added
- **Friendly plugin type labels.** Kong's plugin names are cryptic shorthand, so
  every plugin now shows a readable Vietnamese label next to (or in place of) the
  raw name — `key-auth` → "API key", `acl` → "ACL · phân quyền", `ip-restriction`
  → "Giới hạn IP", `rate-limiting` → "Giới hạn tần suất", `file-log` → "Ghi log
  file", etc. Applied in the Plugins tab (core + other rows), Topology chips and
  the Models Security column; the raw Kong name stays visible for reference.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.4.1.sha256.txt
tar xzf kong-pca-bundle-v1.4.1.tar.gz && cd v1.4.1
sudo ./pca-deploy.sh kong-deploy-v1.4.1.tar.gz --cert-ip <PCA_IP>
```

## [1.4.0] — 2026-09-15

### Added
- **Plugin deep-links from Models and Routes.**
  - **Models** — each plugin chip in the Security column is now clickable: it
    switches to the Plugins tab, selects that service and opens the plugin's
    editor, so you can adjust it without hunting for it.
  - **Routes** — a **Plugins** button per route opens the Plugins tab for that
    route's model to manage the plugins that apply to it.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.4.0.sha256.txt
tar xzf kong-pca-bundle-v1.4.0.tar.gz && cd v1.4.0
sudo ./pca-deploy.sh kong-deploy-v1.4.0.tar.gz --cert-ip <PCA_IP>
```

## [1.3.1] — 2026-09-15

### Added
- **Auto-naming plugins on create.** Every plugin created through the portal
  (Register Model, Wizard, Plugins tab, Topology, ACL / consumer flows) now gets
  a readable `instance_name` — `<plugin>-<scope>` derived from the target (e.g.
  `key-auth-svc-coder`, `ip-restriction-con-prj-n8n`) — unless one was typed. A
  plugin is never created unnamed, so the Plugins/Topology views are always
  legible. Implemented once in the API layer so it covers every current and
  future creation path; the existing **Auto-name** button still handles plugins
  created outside the portal.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.3.1.sha256.txt
tar xzf kong-pca-bundle-v1.3.1.tar.gz && cd v1.3.1
sudo ./pca-deploy.sh kong-deploy-v1.3.1.tar.gz --cert-ip <PCA_IP>
```

## [1.3.0] — 2026-09-15

Consolidated Projects into Consumers to remove the Project/Consumer overlap.

### Changed
- **Removed the "Projects" sidebar tab.** A Project was only a naming convention
  over a Consumer (`prj-*`), so the two tabs duplicated each other. Everything a
  Project needed now lives on other tabs:
  - **Consumers** — the single place for consumers/projects. The Edit form now
    also sets **Allowed IPs** (creates/updates/removes the `ip-restriction`
    plugin). Plus the existing **Convert to project** (rename legacy → `prj-*`).
  - **Wizard** — create a project with a token + models in one guided flow.
  - **Access (ACL)** — manage which projects reach which models.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.3.0.sha256.txt
tar xzf kong-pca-bundle-v1.3.0.tar.gz && cd v1.3.0
sudo ./pca-deploy.sh kong-deploy-v1.3.0.tar.gz --cert-ip <PCA_IP>
```

## [1.2.2] — 2026-09-15

### Added
- **Grafana links** — a sidebar **Grafana** entry and a **Grafana ↗** button in
  the Usage tab open the historical per-consumer dashboard
  (`http://<gateway>:3000/d/kong-overview`) in a new tab. The host is taken from
  the page (defaults to the gateway host on port 3000) and can be overridden with
  `localStorage['grafana_url']` if the monitoring stack lives elsewhere. Portal
  Usage stays the live per-consumer request/bandwidth snapshot; Grafana is the
  history/trends view.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.2.2.sha256.txt
tar xzf kong-pca-bundle-v1.2.2.tar.gz && cd v1.2.2
sudo ./pca-deploy.sh kong-deploy-v1.2.2.tar.gz --cert-ip <PCA_IP>
```

## [1.2.1] — 2026-09-14

Consumer/project consolidation and a clearer, consumer-centric Usage view.

### Added
- **Convert to project** button on legacy consumers (Consumers tab) — renames a
  consumer to `prj-*` so it shows up as a Project. Keys, ACL membership and IP
  restriction are preserved (they bind to the consumer id, not the name), so no
  traffic is affected.
- **Usage → Group by consumer** (default on) — one row per consumer with the
  total requests / 5xx / bandwidth and a per-model breakdown (each model with its
  request count), so a consumer that spans several models is a single line
  instead of scattered rows. Untick to get the flat consumer×model table.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.2.1.sha256.txt
tar xzf kong-pca-bundle-v1.2.1.tar.gz && cd v1.2.1
sudo ./pca-deploy.sh kong-deploy-v1.2.1.tar.gz --cert-ip <PCA_IP>
```

## [1.2.0] — 2026-09-11

Access control as a first-class feature, and full inline editing in Topology.

### Added
- **Access (ACL) tab** — central management + audit. Lists every ACL group with
  the services that allow it and its member projects; **add/remove members** and
  service **allow-lists** inline (× on any chip revokes). Two toolbars: *Add
  member* (consumer → group) and *Allow group on service*. An **audit panel**
  flags open (no-ACL) services, services with ACL but no key-auth, empty
  allow-lists, and stray **global** auth plugins.
- **Topology inline CRUD** — every entity is now editable from the map:
  - Service: **Edit** backend URL, **Delete** (cascades routes + plugins).
  - Routes: **add**, **edit paths**, **delete**.
  - Plugins: **add** (schema-driven form in a modal), **edit** config +
    instance name + enabled, **delete** — reusing the Plugins-tab form engine.
  - ACL groups: **allow** a group on a service, **remove** it.
  - Memberships: **remove** a consumer from a group directly on its row.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.2.0.sha256.txt
tar xzf kong-pca-bundle-v1.2.0.tar.gz && cd v1.2.0
sudo ./pca-deploy.sh kong-deploy-v1.2.0.tar.gz --cert-ip <PCA_IP>
```

## [1.1.0] — 2026-09-11

Milestone release. Rolls up everything through 1.0.18 and makes the running
version visible, so a wrong-bundle deploy can't go unnoticed.

### Added
- **Portal shows its release version** — the sidebar footer displays `v<version>`
  (injected into `portal.html` at build time from the `VERSION` file).

### Fixed
- **Deploy banner shows the real deployed version** — it now reads
  `<install>/VERSION` and prints it, and drops a stale hard-coded "new features"
  list. Deploying the wrong (older) tarball is now obvious immediately.
- **Rebrand smoke-test** no longer false-warns — the post-upgrade check matched a
  stale uppercase brand string; it is now case-insensitive (carried from 1.0.17-fix).

### Included since 1.0.15
Login/user/audit redesign, self-service forgot-password, portal API-base guard,
ACL groups → members, Wizard "existing ACL group(s)" mode, plugin Auto-name +
core-plugin instance-name editing + descriptions, and the access-control /
upstream docs + diagram.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.1.0.sha256.txt
tar xzf kong-pca-bundle-v1.1.0.tar.gz && cd v1.1.0
sudo ./pca-deploy.sh kong-deploy-v1.1.0.tar.gz --cert-ip <PCA_IP>
```

## [1.0.18] — 2026-09-10

ACL visibility, ACL-only onboarding, and plugin naming.

### Added
- **ACL groups → members** table in the Consumers tab — the inverse of the
  per-consumer group list: which consumers belong to each ACL group. Reuses the
  data already loaded (no extra API calls); has its own filter.
- **Wizard mode "Add a project to existing ACL group(s)"** — onboard a new
  project and grant it access to one or more existing ACL groups (multi-select,
  choose key header), skipping model/route creation. The consumer is created,
  keyed, joined to every ticked group, and optionally IP-restricted.
- **Auto-name plugins** (Plugins tab) — scans every plugin gateway-wide with no
  `instance_name` and assigns a readable one following `<plugin>-<scope>` (e.g.
  `key-auth-svc-coder`, `ip-restriction-con-prj-app`); previews the plan and
  skips already-named plugins.
- **Edit** on the core key-auth / acl rows so their `instance_name` can be set
  in the UI (previously only non-core plugins were editable).
- Plain-language **plugin descriptions** on hover (Plugins tab + Topology).
- Docs: `diagram-access-control.svg` and a new **§5 Access control & scaling**
  section in the Model Portal guide (path-per-model + upstream load-balancing).

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.18.sha256.txt
tar xzf kong-pca-bundle-v1.0.18.tar.gz && cd v1.0.18
sudo ./pca-deploy.sh kong-deploy-v1.0.18.tar.gz --cert-ip <PCA_IP>
```

## [1.0.17] — 2026-08-17

Hardened the portal's API base against a stale localStorage override.

### Fixed
- The Model Portal read an optional `kong_api` base URL from `localStorage`
  without validating it. A leftover absolute override pointing at a dead host or
  port (e.g. an old `http://<gw>/aigw/api` on port 80) forced every Admin-API
  call there and surfaced as `ERR_CONNECTION_REFUSED`, even though the portal
  itself was served correctly on `:8002`. The override is now honored only when
  it is a relative path or a same-origin absolute URL; anything cross-origin is
  ignored and the portal falls back to the relative `/aigw/api` (same origin).
  No rebuild needed to recover an affected browser — clear it with
  `localStorage.removeItem('kong_api')` and reload.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.17.sha256.txt
tar xzf kong-pca-bundle-v1.0.17.tar.gz && cd v1.0.17
sudo ./pca-deploy.sh kong-deploy-v1.0.17.tar.gz --cert-ip <PCA_IP>
```

## [1.0.16] — 2026-08-17

Added self-service **forgot password** to the login page.

### Added
- **Forgot password flow** — a "Forgot password?" link on the login page opens a
  reset form: enter your username, a 6-digit code is emailed (reusing the same
  email-MFA infrastructure), then set a new password. Two new endpoints:
  `POST /auth/forgot` (issues + emails the code, masks the address, returns the
  challenge id) and `POST /auth/reset` (verifies the code, sets the new password
  with an APR1 hash, clears any lockout). IP lockout, code TTL, attempt limits
  (410 on exhaustion/expiry) and error handling mirror the existing MFA path.
- Login page gains **forgot** and **reset** steps with matching ITPortal-blue
  styling — leading-icon inputs, a segmented 6-digit code field, show/hide
  password toggle, resend countdown, and a "Back to sign in" link.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.16.sha256.txt
tar xzf kong-pca-bundle-v1.0.16.tar.gz && cd v1.0.16
sudo ./pca-deploy.sh kong-deploy-v1.0.16.tar.gz --cert-ip <PCA_IP>
```

## [1.0.15] — 2026-08-17

Redesigned the login / user-management module to match the Model Portal.

### Changed
- **Login page** rebuilt — SEHC INFRA logo, ITPortal blue, Inter, light + dark
  themes, animated gradient backdrop, icon-tiled card with a top accent line,
  inputs with leading icons + a show/hide password toggle, styled loading/error
  states. The password → email-MFA (6-digit) → redirect flow and all endpoints
  (`/auth/login`, `/auth/mfa`, `/auth/mfa/resend`) are unchanged.
- **User Management** (`/users/`) and **Audit Log** (`/logs/`) restyled to the
  same design system — clean top bar with the SEHC INFRA logo, icon-tiled cards,
  blue/amber/red action buttons, role badges, light + dark. All user/SMTP/audit
  functionality and endpoints are unchanged.
- Cross-links now point between User Management, Audit Log, **Model Portal** and
  Kong Manager.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.15.sha256.txt
tar xzf kong-pca-bundle-v1.0.15.tar.gz && cd v1.0.15
sudo ./pca-deploy.sh kong-deploy-v1.0.15.tar.gz --cert-ip <PCA_IP>
```

## [1.0.14] — 2026-08-10

### Added
- **"Make managed" button.** Any service missing key-auth or acl (typically a
  legacy / open service) shows a one-click **Make managed** action in the Models
  tab: it adds **key-auth** (choose the header) and an **acl** group (`acl-<name>`),
  turning an open service into an access-controlled one — after which you can grant
  projects to it (Projects/Wizard), see its consumers in Topology, etc. Fully-
  secured services don't show the button.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.14.sha256.txt
tar xzf kong-pca-bundle-v1.0.14.tar.gz && cd v1.0.14
sudo ./pca-deploy.sh kong-deploy-v1.0.14.tar.gz --cert-ip <PCA_IP>
```

## [1.0.13] — 2026-08-10

### Fixed
- **Assign a project to any service (incl. legacy).** The Projects "assign" model
  list only offered `svc-*` models and hard-coded the group as `acl-<slug>`. It now
  lists **all** services, resolves each service's **real ACL group** from its acl
  plugin, and can grant a project to legacy services too. Services with **no ACL**
  are shown but disabled with a hint to add one in Plugins (you can't ACL-scope an
  open service). Project edit and the add/remove diff now use the resolved groups.

### Notes
- Full audit: every management function now works on **all configured objects**,
  not just convention (`svc-`/`prj-`) ones — Models (show-all), Routes, Consumers,
  Plugins, Upstreams, Projects, Topology, Test, Backup. The **Topology** tab is the
  all-objects map; Overview remains the convention summary.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.13.sha256.txt
tar xzf kong-pca-bundle-v1.0.13.tar.gz && cd v1.0.13
sudo ./pca-deploy.sh kong-deploy-v1.0.13.tar.gz --cert-ip <PCA_IP>
```

## [1.0.12] — 2026-08-10

### Fixed
- **Manage plugins on legacy services.** The Plugins tab model picker only listed
  convention (`svc-*`) services, so legacy services (e.g. `1`) couldn't have their
  plugins viewed, added (with instance names) or edited. It now lists **all**
  services — convention ones first, legacy ones labelled `(legacy)`. (Topology,
  Models show-all/edit, and the Wizard's "existing model" mode already covered
  legacy; the Plugins tab was the remaining gap.)

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.12.sha256.txt
tar xzf kong-pca-bundle-v1.0.12.tar.gz && cd v1.0.12
sudo ./pca-deploy.sh kong-deploy-v1.0.12.tar.gz --cert-ip <PCA_IP>
```

## [1.0.11] — 2026-08-10

### Added
- **Init plugins at service creation.** The Register Model form and the Setup
  Wizard now have an optional "Init plugins" picker — add one or more plugins to
  the new service (each with an optional **instance name**) right when it's
  created, on top of the automatic key-auth + acl.
- **Topology shows the API key.** The "Consumers that can call this" table now has
  an **API key** column — masked by default, with a reveal (eye) toggle and
  click-to-copy — so you can see the exact key each project uses per service.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.11.sha256.txt
tar xzf kong-pca-bundle-v1.0.11.tar.gz && cd v1.0.11
sudo ./pca-deploy.sh kong-deploy-v1.0.11.tar.gz --cert-ip <PCA_IP>
```

## [1.0.10] — 2026-08-10

### Added
- **Client access URLs.** The Topology tab and the Overview "Models" table now
  show the exact URL a client calls for each route — both **`http://<gateway>:8000<path>`**
  and **`https://<gateway>:8443<path>`** — using the host the portal is opened on
  (so on PCA it reads e.g. `http://107.118.99.200:8000/abc`). Click a URL to copy
  it. Services with no route are flagged "not reachable".

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.10.sha256.txt
tar xzf kong-pca-bundle-v1.0.10.tar.gz && cd v1.0.10
sudo ./pca-deploy.sh kong-deploy-v1.0.10.tar.gz --cert-ip <PCA_IP>
```

## [1.0.9] — 2026-08-10

Tell plugins apart and see the whole gateway at a glance.

### Added
- **Topology tab** — one holistic map of the gateway: each service shown with its
  routes, its plugins (by name **and instance name**, with a config summary), its
  ACL groups, and the consumers that can call it (via which group, key count,
  allowed IPs). Answers "which service uses which route / plugin / ACL / consumer"
  in a single screen, with a live filter across service / plugin / consumer.
- **Plugin instance names.** Plugins can now be given an `instance_name` when
  added or edited, and the Plugins tab shows it as the primary label (with the
  plugin type as a sub-tag) — so multiple plugins are easy to tell apart instead
  of a wall of same-typed rows.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.9.sha256.txt
tar xzf kong-pca-bundle-v1.0.9.tar.gz && cd v1.0.9
sudo ./pca-deploy.sh kong-deploy-v1.0.9.tar.gz --cert-ip <PCA_IP>
```

## [1.0.8] — 2026-08-07

UX polish + a portal-serving reliability fix, from a parallel UX-review + QA-agent
cross-check of all 13 tabs (all functions verified PASS, 0 JS errors).

### Fixed
- **Portal survives a file swap.** The auth-proxy bind-mounted the *single file*
  `portal/portal.html`; replacing it on the host (new inode) made nginx **404
  `/kongportal`** until a container restart. Now the **directory** is mounted
  (`./portal → /etc/nginx/model-portal`, `alias …/portal.html`), so updating the
  file is served immediately — verified by rewriting the file live (stays 200).
- **Plugins tab used emoji** for the built-in protections (🔑 key-auth, 👥 acl,
  ⏱ rate-limiting, 📦 request-size-limiting, 🤖 bot-detection, 🌐 cors, 🔌) — now
  inline **SVG (Heroicons-style)**, so they're consistent and render correctly in
  dark mode.
- **No horizontal overflow on mobile (≤640px).** Grid `.split` children now carry
  `min-width:0` so wide tables scroll inside their own container instead of
  pushing the page; card-header toolbars wrap; schema-form (`.pfrow`) inputs go
  full-width. Verified 0 overflow across all 13 tabs at 375px.
- **Requests** status codes render as **semantic badges** (not bare colored text).
- **Test** body textarea is monospace and taller; **Backup** file input + all
  textareas are styled for dark mode (no white flash) and the export counts sit in
  a 2-column grid.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.8.sha256.txt
tar xzf kong-pca-bundle-v1.0.8.tar.gz && cd v1.0.8
sudo ./pca-deploy.sh kong-deploy-v1.0.8.tar.gz --cert-ip <PCA_IP>
```

## [1.0.7] — 2026-08-07

Portal layout fix — fill wide screens.

### Fixed
- **The portal now fills wide monitors.** The content container was hard-capped
  at `max-width:1180px`, leaving a ~500px empty band on the right of a 1920px
  screen (the topbar filled, the body did not — looking "squished"). Raised the
  cap to a full-width workbench (`max-width:2100px`, centered) so it fills up to
  ~2340px windows and only centers on ultra-wide (2560/3440) for readable line
  lengths. Verified from 320→2560px with no horizontal overflow.
- **Wizard and Plugins tabs** (each a single fixed-width card) are now centered
  instead of left-dumped, so their whitespace is balanced.
- **Collapsed sidebar (<900px)** hardened: the wide logo no longer overflows the
  64px rail (it was overlapping the page title), the connection-status text is
  hidden, and the footer toggle is centered.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.7.sha256.txt
tar xzf kong-pca-bundle-v1.0.7.tar.gz && cd v1.0.7
sudo ./pca-deploy.sh kong-deploy-v1.0.7.tar.gz --cert-ip <PCA_IP>
```

## [1.0.6] — 2026-08-07

Portal management upgrades — cover the full Kong object model, make plugin config
foolproof, add a Setup Wizard, and align the UI to the IT Portal design system.
The portal is now a full web console (13 tabs) beside `kong-manage.sh`; see
`docs/confluence/09-model-portal.md`.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.6.sha256.txt
tar xzf kong-pca-bundle-v1.0.6.tar.gz && cd v1.0.6
sudo ./pca-deploy.sh kong-deploy-v1.0.6.tar.gz --cert-ip <PCA_IP>
```
Upgrade-safe: no `down -v`, a `pg_dump` backup is taken first, and only changed
containers restart. After deploy, open `https://<PCA_IP>:8452/kongportal` and
check the Overview health strip has **no** stray global-auth warning.

### Added
- **Consumers tab** — add any consumer (incl. non-convention / legacy names),
  manage ACL group membership (add/remove groups), and **issue / view / delete
  API keys** (`key-auth` credentials — blank = auto-generate a 36-char secure
  key). Lists **every** consumer with its groups, keys and tags, so pre-existing
  config (e.g. `n8n`) is visible, not hidden by the `prj-` convention.
- **Upstreams tab** — create load-balancing pools (round-robin / least-connections
  / consistent-hashing), add backend targets (`host:port` + weight) with health
  badges, remove targets or delete upstreams. Point a model's backend host at an
  upstream name to spread traffic across targets.
- **Usage tab** — per-consumer traffic **broken down by model**: requests, 5xx
  errors and in/out bandwidth for each `consumer × service`, parsed live from
  Kong's Prometheus metrics. A new admin-gated `/metrics` nginx location proxies
  the read-only Status API (`:8100/metrics`) so the SPA can read it same-origin;
  only key-auth-authenticated traffic is attributed to a consumer.
- **Requests tab** — recent requests with **source IP**: time, client IP,
  consumer, model, status and latency (who called which model from where).
  Backed by a global **`file-log`** plugin writing one JSON line per request to
  a shared `data/reqlog/requests.log`; nginx serves it read-only at `/requests`
  (admin-gated) and the SPA Range-fetches only the tail. `pca-deploy.sh` enables
  the plugin, creates the dir, and installs a **logrotate** rule (10M ×3) so the
  log cannot fill the disk. Note: behind an L4 proxy, set Kong `trusted_ips` +
  `real_ip_header` to log the true client IP instead of the proxy's.
- **"Show all (incl. legacy)"** toggle on the Models tab — lists every Kong
  service, tagging non-`svc-` ones as `legacy`, so pre-existing services appear.
- **Inline edit** on Models rows — change a service's backend URL and route path
  (works for `svc-*` and legacy services).

### Changed (Design — align to IT Portal)
- Re-aligned the portal to the **IT Portal design system** (`/DATA/itportal`
  DESIGN.md): default primary shifted to Action Blue **#3b82f6** (hover #2563eb),
  gradient primary/danger buttons with a colored shadow and focus ring, ink text
  **#0f172a**. Sidebar emoji icons replaced with **inline SVG (Heroicons-style)
  outline icons** — self-hosted, air-gap safe. Stat cards gained a colored top
  accent and a lift-on-hover, matching the IT Portal dashboard. Both light and
  dark themes verified.
- Card headers now use **colored gradient icon tiles** (blue/violet/green/amber/
  sky) with white Heroicons-style SVGs — matching the IT Portal Quick-Actions
  style — replacing the remaining emoji in section titles.

### Added (Setup Wizard)
- **Wizard tab** — a 4-step guided flow (Model → Route → Project → Review) that
  provisions a full working path in one shot: a service (`svc-<slug>` + key-auth
  + `acl-<slug>`), its route, and a project (`prj-<name>` with token, ACL
  membership and optional IP restriction), ending in a review summary. The last
  emoji (Generate, reveal) are now inline SVG too.
  - **Two modes:** *Create a new model* (greenfield) or *Use an existing model*
    — the latter skips service/route creation, auto-detects the model's ACL
    group / key-header / route, and just adds a new project to it. New mode
    **guards against an existing slug** (won't overwrite a model) — telling you
    to switch to existing mode instead.

### Added (Governance & convenience — P2)
- **Audit tab** — admin change log: who did what (actor, source IP, method →
  Create/Update/Delete, object, result), newest first, defaulting to changes
  only (hides reads) with a text filter. Surfaces the existing nginx audit log
  via a new admin-gated `/auditlog` location (Range-tailed like Requests).
- **CSV export** on the Usage and Requests tabs — one-click download for
  reporting/spreadsheets.
- **Quick filters** on the Models, Routes, Consumers and Projects tables —
  instant client-side row filtering.

### Added (Operations — P1)
- **Test tab** — send a real request through Kong with a chosen project's key and
  see the status, latency and response body. Goes through the actual key-auth /
  ACL / routing pipeline via a new admin-gated `/modeltest/` nginx location that
  proxies the Kong proxy port (`:8000`), so 401 (bad key), 403 (ACL) and 5xx
  (upstream) are all reproduced exactly like a client would see them.
- **Health strip on Overview** — Kong version, database reachability, active
  connections and upstream target health, with a re-check link. Also **flags a
  stray GLOBAL auth plugin** (basic-auth / key-auth / jwt / oauth2 / hmac-auth /
  ldap-auth / mtls-auth): such a plugin applies to every route and 401s all
  API-key traffic — a red banner warns to remove it unless intentional.
- **Backup tab** — **Export** the whole gateway config (services, routes,
  plugins, consumers, ACLs, API keys, upstreams, targets) to a JSON file, and
  **Restore** it from a file. Restore upserts every entity by id (idempotent —
  updates existing, recreates missing) and never deletes. Verified via a headless
  round-trip (export → delete a service → restore → service recreated with its
  route). The export contains API keys in clear text — store it securely.

### Added (CRUD completeness — P0)
- **Routes tab** — routes are first-class now: list every route (path, service,
  methods, strip_path), add many routes per service (paths / methods / hosts /
  strip_path), edit and delete them. Fills the "one service = many routes" gap.
- **Delete a model** — Models rows get a Delete that removes the service, all its
  routes and plugins (consumers/keys untouched).
- **Edit a project** — change a project's allowed models (ACL groups), IPs and
  tags without delete-and-recreate; the token is preserved. ACL membership is
  diffed (adds selected, removes deselected); clearing IPs removes the
  ip-restriction.
- **Edit any plugin** — every attached plugin (not just the curated toggles) gets
  an Edit that opens the schema-driven form prefilled with its current config;
  enable/disable and delete were already there.
- **Edit a consumer** — rename (PATCH by id, so keys/ACL survive) and change tags
  from the Consumers tab.

### Changed
- **Legacy config is no longer hidden.** The Models list defaults to **showing
  all** services with a `managed` / `legacy` badge (was: convention-only with an
  opt-in "Show all"). Nothing is hidden by default.
- **Plugin config is now a schema-driven form, not raw JSON.** The "Add any
  plugin" picker renders typed inputs generated from the plugin's Kong schema
  (`GET /schemas/plugins/<name>`) — number / text / checkbox / select (one_of) /
  comma-list (arrays), prefilled with defaults. Filling the fields builds and
  POSTs the config automatically; the error-prone JSON textarea is gone.

### Notes
- Portal changes are UI-only over the existing authenticated `/api` Admin proxy —
  no schema, port, or auth changes. Rebuild the PCA bundle to ship these.

## [1.0.5] — 2026-07-28

Model & Project self-service portal, integrated into the console over HTTPS.

### Added
- **Model & Project Portal** at `/kongportal` (also `/aigw/kongportal` via the IT
  Portal forward). A single-page admin UI over the Kong Admin API implementing the
  3-axis convention: register models (`svc-<slug>` + route + tags), assign projects
  (`prj-<slug>` consumers with their own token + IP), an **Overview** with a
  model↔project access matrix, and a **Plugins** tab (per-model protection toggles
  for key-auth/acl/rate-limiting/request-size-limiting/bot-detection/cors, plus a
  full picker for any Kong plugin with JSON config). ITPortal styling — SEHC INFRA
  logo, blue/slate palette, Inter, dark mode.
- Served **behind the same admin login as the console** (`_auth_check_admin`):
  anonymous users are redirected to `/auth/login`, non-admins get 403. Its API
  calls reuse the authenticated `/api` Admin proxy — no new auth surface. Switch
  links added between the console and the portal.
- **HTTPS on the auth-proxy** (`listen 443 ssl`, published on `:8452`) using the
  box's self-signed cert (`ssl/kong-proxy.*`, generated by `ensure_proxy_cert`).
  HTTP `:8002` is kept for the IT Portal forward.

### Notes
- `portal/serve-portal.py` is a DEV-only helper (no auth); production access is
  `/kongportal` behind the login.

## [1.0.4] — 2026-07-26

Monitoring release: turn on vLLM token monitoring end-to-end and ship it to PCA.

### Added
- **vLLM scrape job** in `monitoring-preview/prometheus.yml` (`job_name: vllm` via
  `file_sd_configs`), plus `vllm-targets.yml` pre-populated with the 7 production
  vLLM hosts (`107.118.109.31–36`, `.46`). Prometheus hot-reloads the target file
  (~30s) — add/remove machines without a restart.
- Grafana **"vLLM Token Usage"** panels (token rate by model/machine) are wired to
  the same Prometheus datasource that scrapes Kong — one stack monitors both.

### Notes
- Each vLLM host must run **without** `--disable-log-stats`, listen on
  `0.0.0.0:<port>`, and allow the Prometheus host through the firewall.
- A separate share-externally dashboard variant (datasource prompt on import +
  Grafana-12-compatible ranked tables) is available for importing into other
  Grafana instances; the provisioned copies keep concrete datasource UIDs.

## [1.0.3] — 2026-06-15

Security hardening, full monitoring + alerting, and a documentation refresh.

### Highlights
- 🔒 **Admin-only console** — Kong Manager and the Admin API are now restricted to
  `admin`-role accounts.
- 🔐 **Proxy HTTPS** on `:8443` with a self-signed, per-box IP certificate.
- 📊 **Monitoring** — metrics exposed for Zabbix and Grafana, plus a self-contained
  Prometheus + Loki + Grafana preview stack with dashboards, logs, and alerts.

### Added
- **Proxy HTTPS on `:8443`** using a self-signed certificate whose SAN matches the
  box IP. `pca-deploy.sh` generates it automatically (`--cert-ip <ip>` to set the
  IP explicitly; auto-detect skips Docker bridge addresses). Port `8000` stays
  plain HTTP, so existing clients (e.g. n8n → Ollama) are unaffected.
- **Metrics via the Prometheus plugin**, exposed on a read-only **Status API
  (`:8100/metrics`)**. Enabled automatically on deploy; persists in Postgres.
  Status/latency/bandwidth/per-consumer metrics included.
- **Zabbix 7.0 template** (`zabbix/template_kong_http.xml`) — HTTP-agent scrape
  with Prometheus preprocessing, per-route LLD discovery, and triggers
  (datastore down, metrics unreachable, high 5xx). See `zabbix/README.md`.
- **DEV monitoring preview stack** (`monitoring-preview/`) — Prometheus + Loki +
  Grafana, with an 18-panel dashboard: health, request/error rates, latency
  (p95/p99), bandwidth, **consumption breakdown and ranking by route / service /
  consumer**, and **error + audit log panels** (Loki + Promtail, scoped to the
  Kong stack). Ships as its own **air-gapped bundle**
  (`scripts/build-monitoring-bundle.sh` → `kong-monitoring-bundle-v*.tar.gz`:
  config + 6 Docker images + `deploy-monitoring.sh`), separate from the lean
  gateway bundle, so it can run on PCA.
- **Alerting** — Grafana-managed alert rules (datastore down, Kong down, high 5xx)
  routed to a contact point with **email + webhook** integrations; verified
  end-to-end on DEV. Zabbix alerting (Email + Webhook media + trigger action)
  documented in `zabbix/README.md`.
- **`reset-password.sh`** — admin recovery tool. Resets a user's password and
  clears their lockout (and any IP locks) via `docker exec`, with no console
  login required — so a locked-out or forgotten-password admin can be recovered
  even though the console is admin-only. `--admin` ensures the admin role;
  `--unlock-only` just lifts the 15-minute lock.
- **Client cert-trust scripts** (`client/`) — `trust-kong-cert.sh` (Linux:
  Debian/Ubuntu + RHEL/Fedora) and `trust-kong-cert.ps1` (Windows) so client
  machines trust the self-signed proxy cert and call `:8443` over HTTPS without
  `-k` / "allow self-signed".
- **Documentation** — `docs/MONITORING.md` (full monitoring deployment guide,
  Zabbix and Prometheus/Grafana paths).

### Changed
- **BREAKING (behavior):** `/`, `/users/`, `/logs/`, and `/api/` now require the
  `admin` role at the nginx layer (new `/auth/check/admin` gate). Kong Manager OSS
  has no built-in RBAC, so any logged-in user previously could read keys/secrets
  via the Admin API. A `user`-role account can still authenticate but receives a
  styled **403** on every console surface.
- `docs/DEPLOY.md` and `PCA-UPGRADE-GUIDE.md` refreshed around the unified
  `pca-deploy.sh` (fresh + upgrade auto-detect), with updated ports and v1.0.3
  surfaces.
- `pca-deploy.sh` now also generates the proxy TLS cert and enables the Prometheus
  plugin during both fresh installs and upgrades (idempotent).
- `build-release.sh` excludes `monitoring-preview/` from the PCA bundle.

### Fixed
- Proxy TLS cert unreadable by Kong on a normal filesystem: the cert key was
  created `600` and root-owned, but Kong runs as a non-root user (uid/gid 1001),
  so it could not load TLS and the container never became healthy ("dependency
  failed to start: container kong is unhealthy"). `pca-deploy.sh` now sets
  group/world-readable perms and re-asserts them on re-run.
- Stale documentation referencing the retired `pca-upgrade.sh` script (unified
  into `pca-deploy.sh`).

### Upgrade notes
- **Existing Kong config is preserved.** Services, routes, plugins, and consumers
  live in the `kong_pg_data` Postgres volume, which the upgrade does not destroy
  (it takes a `pg_dump` backup only). Users, roles, audit, SMTP, `.env`, and
  `nginx/.htpasswd` are likewise preserved.
- **Check user roles before upgrading.** Any `user`-role account will lose access
  to the console (403). Promote anyone who needs admin access first.
- **Set `--cert-ip <PCA_IP>`** when deploying so the TLS cert SAN matches how
  clients reach `:8443`.
- **Open `tcp/8100`** from the monitoring host (Zabbix / Prometheus) to the box.

### Deploy
```bash
sha256sum -c kong-pca-bundle-v1.0.3.sha256.txt
tar xzf kong-pca-bundle-v1.0.3.tar.gz && cd v1.0.3
sudo ./pca-deploy.sh kong-deploy-v1.0.3.tar.gz --cert-ip <PCA_IP>
```

## [1.0.2] — earlier

- Renamed the URL path prefix `/kong` → `/aigw`.
- Self-contained release directory and single-file bundle; unified
  `pca-upgrade.sh` + `deploy.sh` into one `pca-deploy.sh` (auto-detects fresh vs
  upgrade); air-gap fixes (no `alpine:latest`, `pg_dump` for backups).

[1.0.3]: https://github.com/minh0607/kong-gateway/releases/tag/v1.0.3
