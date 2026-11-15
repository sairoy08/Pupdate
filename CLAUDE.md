# Pupdate: notes for the next agent

**Naming.** The product is called **Pupdate** (renamed from Pupdate). The code uses it too: the Xcode project, targets,
scheme and folders (`Pupdate`, `PupdateWidgets`, `PupdateUITests`), Swift type names and logger names. A few internal
identifiers deliberately keep the old name, because renaming them breaks things that already exist: bundle IDs
(`com.walkbuddy.app.*`, a change installs a second app and needs new provisioning), server paths and the systemd unit
(`/opt/walkbuddy`, `walkbuddy`, `/etc/walkbuddy.env`), the MongoDB database `walkbuddy` (holds the live state), the SSH key
`walkbuddy_vultr`, and UserDefaults keys (`wb.*`). Use "Pupdate" everywhere else. The URL scheme is `pupdate://`.

Read `README.md` first for what the product does. This file covers how the code is laid out, how to change it without breaking the demo, and what is still open.

## Ground rules

- **The safety path never waits on AI.** Every Gemini call has an instant fallback. Check-ins and alerts must still fire if Gemini is down, slow or has no key. Keep it that way: Gemini runs in background threads and writes into state when it answers (`buddy_ai.fill_async`, `pace._start_judge`).
- **The engine is pure and time-injected.** `backend/app/engine.py` has no I/O and no wall clock. Change it only with tests in `tests/test_engine.py` and `tests/test_petting_intervals.py`.
- **The demo sim never pets.** Every pet comes from the phone.
- **Duress is invisible to the walker.** `walk_view(viewer="walker")` strips it. Never leak it into the walker's UI, the Live Activity or the logs shown to the walker.
- **Only a friend closes an alert.** The walker can't, and a late pet doesn't either.
- **Run tests before every deploy:** `cd backend && .venv/bin/pytest -q` (92 should pass), plus the UI suite below.

## Layout

```
backend/app/
  engine.py     state machine: calm -> checkin -> nudge -> final -> countdown -> alert; per-walk stage lengths
                (make_stages), checkins_off, 90 s lost-contact watchdog
  walks.py      STATE (users, walks, alerts, flags, seq), start_walk, handle(events), alerts + Gemini briefs,
                walk_view (the JSON the phones render), on_position (pace + flags hooks), notices to friends,
                timing_warnings, dump/restore for MongoDB
  pace.py       pace samples every 5 s, rule patterns (running, stop_and_go, backtracking, sudden_stop, vehicle),
                Gemini judge (check_in yes/no + buddy line + friend note), cooldown. ASYNC/_judge_override for tests
  flags.py      flagged spots: avoid/caution/ok, circle visibility (connected()), 7-day expiry, seeds on reset
  nav.py        turn-by-turn: next maneuver from the walker's distance along the route
  routes.py     demo routes (data/routes_graph.json from OSM sidewalks, over the hand-drawn routes_precomputed.json)
                + phone-planned routes (CUSTOM, persisted)
  route_ai.py   Gemini safer-route pick with friends' flags + street rule fallback + "never through Avoid" rule
  buddy_ai.py   Gemini check-in lines, alert briefs, gemini_json helper, fallbacks
  speed.py      real GPS ingest: accuracy filter, car/stop/off-route anomalies, then walks.on_position
  demo.py       sim walker (2x, escalation too), catch-up in 5 s steps, pace modes (run/stop_go/backtrack/car/stop),
                controls (pause/resume, forward/backward, jump 0..1, arrive = walk to the end and finish the walk)
  store.py      persistence: MongoDB snapshot (used on Vultr), Upstash Redis (unused), memory (local)
  main.py       FastAPI routes (see README API table)
swift/
  project.yml   XcodeGen spec (run `xcodegen generate` after adding files). WBDefaultServer = the Vultr URL
  Pupdate/Sources/
    API.swift            Codable models (snake_case -> camelCase) + calls; walkSettings sent with every walk
    Stores.swift         WalkerStore (1 s poll, spoken turns, flag heads-ups), FriendStore (1.5 s poll, alarms,
                         notices), LocationTicker (background GPS on real walks)
    WalkerView.swift     WalkScreen: next turn, buddy, ladder, notices, map + flags, pace card, test tools
    WalkExtras.swift     NextTurnCard, PaceCard, Sparkline, FlagAheadBanner, NoticeList, TestToolsCard
    FlagsView.swift      FlagStore, FlagMarks (MapContent), NewFlagCard, FlagDetailCard, FlagsView
    PlanView.swift       PlannedRoute (Apple route or joined detour), flagsOn, PlanModel (search, alternates,
                         detourIfBlocked, Gemini assess), TripSheet
    SettingsView.swift   check-ins on/off (confirm), schedule, alert timing, accessibility, circle, server, demo.
                         ScreenPanel enum
    HomeView, FriendView, BuddyView (rub-to-pet, 2 s duress), Features (ladder, walk log), Theme, Feedback
  Pupdate/Shared/WalkActivity.swift   Live Activity ContentState (shared with the widget; new fields must be optional),
                                        PetBuddyIntent (Lock Screen Pet button)
  Pupdate/Shared/DogView.swift        the animated vector dog (species "dog"), app + widget. Art: DogArt.swift is GENERATED
                                        from swift/tools/dog_art.py (python3 dog_art.py && python3 gen_dog_swift.py)
  PupdateWidgets/                     Lock Screen + Dynamic Island UI
  PupdateUITests/                     XCUITest end-to-end against the live server (18 tests)
deploy/        vultr-deploy.sh, cloud-init.sh (fresh server)
demo-server.sh laptop fallback (local uvicorn + ngrok)
app/           old Expo prototype, unused
```

## UI conventions that fix real bugs

- **One presenter per screen:** each screen has a single `.fullScreenCover(item: $panel)` driven by `ScreenPanel`. Stacked sheets were being dismissed by polling re-renders. Add new screens as a `ScreenPanel` case, not a new sheet.
- **Publish only on change:** stores compare before assigning `@Published` values (`if w != walk { walk = w }`). Keep that, or every poll re-renders everything.
- **In-place overlays:** the new-flag card on the walk screen is an overlay in the ZStack, not a sheet, for the same reason.
- **Fonts and accessibility:** use `Typeface.*` (Dynamic Type via `relativeTo`), `Palette.*` colors, and `Motion.reduced` for animation. Give new controls accessibility labels or identifiers; the UI tests depend on them.

## Running things

```bash
# backend
cd backend && .venv/bin/pytest -q && .venv/bin/uvicorn app.main:app --port 8100
# app (simulator): find a booted one with `xcrun simctl list devices booted`
cd swift && xcodegen generate && xcodebuild -project Pupdate.xcodeproj -scheme Pupdate \
  -destination 'id=<SIM_ID>' -derivedDataPath build-sim build
# UI tests hit the live server (they reset demo state there)
xcodebuild test ... -only-testing:PupdateUITests/PupdateE2ETests
# physical iPhone (free team F87457F436; the device must be unlocked and trusted)
xcodebuild ... -destination "id=00008130-000C40222E43001C" -derivedDataPath build-dev -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008130-000C40222E43001C build-dev/Build/Products/Debug-iphoneos/Pupdate.app
```

To simulate GPS in the simulator: `xcrun simctl location <SIM_ID> set 33.4195,-111.9345`.

## Deploying

- **Server:** Vultr, Ubuntu 24.04 at 45.76.67.21.
  - Caddy serves `https://45-76-67-21.sslip.io` and proxies to uvicorn on 127.0.0.1:8100.
  - The systemd unit is `walkbuddy`; code lives in `/opt/walkbuddy`; secrets are in `/etc/walkbuddy.env` (MONGODB_URI, GEMINI_API_KEY).
- **SSH:** `ssh -i ~/.ssh/walkbuddy_vultr root@45.76.67.21`.
- **Update:** `cd /opt/walkbuddy && git pull && systemctl restart walkbuddy` (run `pip install -r backend/requirements.txt` if requirements changed).
- **GitHub:** JeremyEltho/Pupdate (public, formerly walkbuddy), branch `main`.
  - The working copy here lives inside the parent hackathon repo (`sunhacks26`, branch master, no remote), so it can't push directly.
  - Pushes go through a separate clone of the GitHub repo (on this Mac: `/Users/Projects/Pupdate`): rsync `walkbuddy/` into it with `--exclude-from=<clone>/.gitignore --exclude .git`, then commit and push from the clone.
  - **Check the diff before committing.** rsync overwrites, so keep README.md in this folder as the source of truth.
- **Never commit secrets.** `.env` files are git-ignored: `walkbuddy/.env` holds VULTR_API_KEY and MONGODB_URI, and the Gemini key is in `../fitcheck/.env`. Don't print their values.
- **State:** a MongoDB Atlas snapshot (db `walkbuddy`, collection `state`, `_id: "state"`), saved after every POST or DELETE and every 5 s. `POST /demo/reset` reseeds users, walks, alerts and seed flags, and keeps the circle, buddy name/species and flags people added.

**Sync rule: pull before you push.** Teammates push to GitHub too. Before rsyncing this folder into the clone:
`git -C <clone> pull --ff-only`, then copy the clone back into this folder (`rsync -a --exclude .git --exclude-from=<clone>/.gitignore <clone>/ walkbuddy/`)
so their changes land here first. Otherwise the rsync overwrites their work. Check `git diff --cached --stat` in the clone before every commit,
and never force-push.

## Demo users

- **jordan:** the walker. Buddy Melvin, a dog at 90 XP, so it evolves at 100 (Puppy -> Scout Pup -> Guardian Dog). Circle: maya and sam.
- **maya:** the friend role on the phone.
- **sam:** another circle member.
- **IDs are hard-coded:** `"jordan"` in WalkerStore and Settings, `"maya"` in FriendStore. There is no auth; that is deliberate for the hackathon.

## Open items, in priority order

1. **Real-device check:** install the latest build on the iPhone. Confirm the Lock Screen Live Activity, including the new turn row, and test the friend role on a second phone. Not yet verified on hardware; the simulator and the UI tests pass.
2. **Friend alerts need the app open:** there are no push notifications (APNs needs a paid developer account).
3. **No auth:** user IDs are trusted from the client.
4. **Walk recap:** a Gemini walk recap and habit notes after a walk (not built).
5. **Demo routes:** built from OpenStreetMap sidewalks by `backend/tools/build_routes.py` into `data/routes_graph.json`, which overrides the
   hand-drawn file. Rerun the tool (it needs osmnx and network, see its docstring) to change endpoints or add a route.
