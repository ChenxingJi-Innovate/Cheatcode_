# Cheatcode_ rules

> Published from the private repository, 10 Oct 2026. The abuse-guard and server-operations sections (R-GUARD-*, R-OPS-*) are left out; references to them below point at the private copy, as do the file paths.

The one library of the rules this product and codebase are built by. Every rule has an id, says why it
exists, how to apply it, and what enforces it. `CLAUDE.md` summarizes the ones every agent must never
break and links here; `docs/ARCHITECTURE.md` describes the mechanisms; `docs/TAXONOMY.md` fixes the words.
A rule changes in this file first, in the same change as the code that follows it.

Ids are `R-<area>-<n>` and never reused. A retired rule stays listed as retired, with the date, so an old
reference still resolves. Terms in **bold** are defined in `docs/TAXONOMY.md`.

Tests keep this file honest: `apps/api/tests/test_docs.py` checks that every id cited in `CLAUDE.md`
exists here, that ids are unique and that each rule carries its four parts.

## Trust

### R-TRUST-1 Trust metrics are computed, never stored
Every number the site shows about usage (**installs**, **active installs**, retention, **rank**,
**momentum**) is derived in `apps/api/app/services/trust.py` from `InstallEvent` and `RunEvent` rows at
read time. There is no editable counter column, no hardcoded figure, and no endpoint that accepts a
statistic from a client. The **ladder** moves only through event rows.
- Why: this is the product's promise. A number nobody can type is a number a visitor can believe.
- How to apply: new metrics are new aggregations in `trust.py`. Caches of computed values are allowed
  when every event write invalidates them (`trust.invalidate()`) and nothing reads them as a source.
  A pre-rendered page may carry a computed value, dated by its render, as long as the live value
  replaces it in the browser (R-PERF-1).
- Enforced by: review of every model and endpoint change; `tests/test_api.py` (counts follow events).
- Since: the founding design, restated in `CLAUDE.md` invariant 1.

### R-TRUST-2 Placement is never paid or hand-placed
No editorial input ranks: **professions**, **toolkits**, **capability tags**, **roles**, picks and
reviews describe listings, they never move them. Nothing in the catalog files feeds `order_key`.
- Why: an editor's taste and a publisher's money must be visibly unable to touch the ladder.
- How to apply: a new catalog file or field is presentation. If a change would make `trust.order_key`
  read it, stop and bring the question to the owner.
- Enforced by: review; `order_key` reads only event aggregates and upstream public numbers.
- Since: 2026-09-24, every catalog addition since repeats it.

### R-TRUST-3 What ranks, in this order
A listing with `DEPLOYS_TO_RANK` (10) or more **installs** in the last seven days ranks by those
installs. Below that it ranks by the **GitHub stars** its source repository gained in the reader's
**date range** (the past week by default; past day, past month or all time on request), ties broken by
the next range and the total. **Runs** never rank. Rank numbers are the ladder's own and never change
with a filter or a sort.
- Why: installs are the only usage the server can observe; runs happen inside the user's client. Below
  the threshold, what is rising on GitHub says more than what is merely large (owner, 2026-09-30).
- How to apply: a sort reorders rows but keeps `rank`; a date range renumbers (it is a different
  ranking), and the page says which range it is on. A listing from a repository shares that
  repository's stars.
- Paused (owner, 2026-10-09: too few installs yet to mean anything): `settings.rank_by_installs` is off
  in production, so stars place every row, the installs and momentum sorts give the ladder order, and
  the site shows no install count (`SHOW_INSTALLS` in `apps/web/lib/format.ts`). Installs are still
  recorded. Turning both back on restores the order above; the tests keep both states covered.
- Enforced by: `tests/test_api.py::test_ladder_ranks_by_deploys_then_stars`,
  `test_installs_do_not_rank_while_switched_off` and the date range tests.
- Since: installs 2026-09-28; stars gained 2026-09-30; date ranges 2026-10-01; installs paused 2026-10-09.

### R-TRUST-4 Upstream numbers are shown, dated, and never edited
Total stars, forks and star gains are the source repository's public counts, fetched (daily for gains),
stored with the day they cover and shown as the upstream's figure, never as ours. We never alter them
and never present them as Cheatcode usage.
- Why: a reader must be able to check the figure on GitHub and find the same number.
- How to apply: `python -m app.refresh_stars` and `tools/refresh_upstream_stats.py` write them;
  nothing else does. The UI names the source and the date (`stars_as_of`, `stats_at`).
- Enforced by: `tests/test_api.py` star tests; review.
- Since: 2026-09-24 (totals), 2026-09-30 (gains), 2026-10-09 (totals read daily with the gains).

## Install

### R-INSTALL-1 One button, never a terminal
Every way to add something from Cheatcode_ ends in a button the user presses: skill packs, **MCP servers**,
plugins, subagents, commands and whole kits, into every supported AI app. The user never has to open a
terminal, paste a command or edit a configuration file to get it working. The terminal is only ever a
secondary option the user chooses for themselves, behind the button on a listing's own page (a tab or an
"other ways" link): never the default, never the only way, never on the home page. This rule ranks above every other rule in this file.
- Why: the audience is product managers, analysts, students and teachers, not developers. A terminal step
  or a config file loses them, and an install they cannot finish is a listing they never use.
- How to apply: build the one click route first (the Cheatcode_ Mac app, an app's own install link such
  as Cursor's or VS Code's, a connector the app adds from a link) and treat any command or paste step as a
  fallback. Where a kind or an app has no one click route yet, the page says so plainly, the gap is listed
  in the roadmap in `docs/ARCHITECTURE.md`, and closing it comes before new surface area. A button still
  shows what it will change and how to undo it, and installs stay verified in the real app (R-PROC-2).
- Enforced by: review of every install surface; `CLAUDE.md` names it first among the invariants.
- Since: 2026-10-07 (owner's rule; one click by default since 2026-10-02).

## Speed and loading

### R-PERF-1 Content first, data after, never a blank wait
Every page's HTML carries all of its text and visual material, and where the page is a list, the rows
as they stood at the last render. Nothing a visitor reads waits on the API or the database. Live
numbers arrive afterwards in the browser, replace what was pre-rendered in place, have a deadline
(15 seconds) and a local retry, and a failure is shown where it happened without emptying the page.
A pre-rendered figure is at most one refresh interval old (five minutes for Browse, one hour for
listing pages) and is replaced within about a second on a working network.
- Why: the owner's rule (2026-09-25 "content first", restated as a hard rule 2026-10-02 after Browse
  sat on "Loading the catalog…" on a campus network): a page that is readable at once is the whole
  product on a slow network; a spinner is a page that does not exist yet.
- How to apply, web: server components fetch page bodies through cached helpers in `lib/api.ts`
  (`next: { revalidate }`), never `cache: "no-store"`. Anything that reads URL query parameters
  (`useSearchParams`) lives in its own tiny component under `<Suspense fallback={null}>`, because Next
  renders that subtree on the client alone; the body around it stays static. Live regions use
  `useLiveResource` or the explorer's keyed fetch. `npm run build` must keep `/`, `/ladder` and
  `/for/*` as static (○ or ●) routes.
- How to apply, api: the responses pages are built from must answer from memory or a cached file (see
  R-PERF-2), so a pre-render never waits on a cold computation either.
- Enforced by: `tests/test_catalog_performance.py`; the deploy check in `deploy/README.md` (a `curl` of
  `/ladder` must contain the search box and rows, not "Loading"); Playwright checks before a web deploy.
- Since: 2026-09-25; hard rule 2026-10-02.

### R-PERF-2 Every page in milliseconds
Catalog reads answer from the in-memory ranking (`trust.ranking()`), rebuilt only when an event
arrives or the catalog changes, never from per-request package scans in production. Listing pages
never call the package manifest or the install plan (both build archives; for a listed repository
that fetches GitHub). Metrics for a set of listings come from a fixed handful of grouped queries,
never one query per listing.
- Why: the database sits across a network; the owner asked for every page in milliseconds
  (2026-09-30).
- How to apply: new ladder work extends `_compute_ladder` or `page()`; new per-listing data joins the
  grouped queries. `PACKAGE_RECHECK_SECONDS=600` in production stops the tree walk.
- Enforced by: `tests/test_catalog_performance.py` (bounded scans and queries); measurements recorded
  in `deploy/README.md` after each speed change.
- Since: 2026-09-24 (navigation), 2026-09-28 (paged ladder), 2026-09-30 (static listing pages).

### R-PERF-3 A restart is never visible
The API reports readiness (`/api/ready`, 200 once the ranking is computed) separately from liveness
(`/api/health`). The container healthcheck uses readiness, the reverse proxy uses liveness, and a
deploy rolls the API over with `docker rollout` so the old container serves until the new one answers
Browse at once. The cold computation of the ranking stays under thirty seconds (23 s on the
production box and 8 s on a Mac, measured 2026-10-03; 60 s before); after every web deploy
`deploy/warm.sh` runs so no visitor renders a page first.
- Why: on 2026-09-30 and 2026-10-01 each API restart stalled Browse for about a minute and returned
  503 for a few seconds; the owner's rule leaves no room for that.
- How to apply: never `docker compose up --force-recreate` a live service; `docker rollout -f
  docker-compose.prod.yml api` and `... web`. Anything added to startup or to `_compute_ladder` is
  measured cold (`deploy/README.md` records the figure) and kept inside the budget.
- Enforced by: `tests/test_api.py::test_ready_reports_a_computed_ranking`; the compose healthcheck;
  the deploy procedure in `deploy/README.md`.
- Since: 2026-10-02.

## API

### R-API-1 One direction: routers, then services, then models
Routers hold no business logic; services never import routers; models know nothing above them.
- Why: every number and every rule has one home, so it can be tested without HTTP and changed once.
- How to apply: a router parses, calls one service function, and shapes the response. Logic that
  appears in a router moves to a service before the change is done.
- Enforced by: review; `CLAUDE.md` invariant 4.
- Since: founding design.

### R-API-2 Schemas are the public contract
`app/schemas/*` is what clients depend on. A response shape is extended, or the endpoint is versioned;
a field is never renamed or removed silently. New fields default so old clients keep working and new
clients can tell an old API (date the field in its comment).
- Why: the website, the installer, the Mac app and anyone scripting the API read these shapes.
- How to apply: add fields with defaults; keep old query values parsing (`sort=stars_week` still
  works); note the date a field appeared.
- Enforced by: review; smoke tests cover each changed endpoint (R-PROC-1).
- Since: founding design; `CLAUDE.md` invariant 4.

### R-API-3 The simulator degrades gracefully and honestly
Without `ANTHROPIC_API_KEY`, or on any API failure, PersonaLens runs in sample mode with
`engine: "sample"` in the payload. Never a 500, never a result labeled `claude` that did not come from
the API. The model id comes from `settings.simulator_model` only.
- Why: a demo that pretends is worse than a demo that says it is a sample.
- How to apply: catch at the service boundary, label the engine, keep sample mode the test default.
- Enforced by: `tests/test_api.py` (sample mode offline); `CLAUDE.md` invariant 3.
- Since: founding design.

### R-API-4 One table of install targets
`apps/api/app/services/targets.py` is the single source of truth for every **target** (AI app) the
installer writes into: directories, layout, how to invoke, how to restart, what was verified when.
`install.sh`, `marketplace.json`, the Mac app's `targets.json` and the website all render from it.
- Why: a directory typed in two places drifts; an install that lands in the wrong folder is invisible.
- How to apply: add or change a target there only; `tools/export_desktop_targets.py` carries it to
  the app; the end-to-end test installs into every target in a throwaway HOME.
- Enforced by: `tests/test_install_e2e.py`; `tests/test_packages.py`.
- Since: 2026-09-24.

### R-API-5 Tests run offline, in sample mode, and cover every endpoint touched
`pytest` needs no network, no key and no hosted database: one temp SQLite with fixture events. Every
new or changed endpoint gets a smoke test in `tests/test_api.py` in the same change.
- Why: a test that needs the internet is a test that gets skipped.
- How to apply: `tests/conftest.py` sets the environment; GitHub and the model provider are never
  called from a test (monkeypatch the fetch).
- Enforced by: CI and the definition of done (R-PROC-1).
- Since: founding design.

## Web

### R-WEB-1 The website is presentation only
`apps/web` never touches the database or the model provider. Server components fetch through
`lib/api.ts`; client components use its `CLIENT_BASE`. No component calls `fetch` against a hand-typed
URL.
- Why: one typed gateway is where caching, deadlines and the internal Docker address live.
- How to apply: add a typed helper to `lib/api.ts`; name it after what it returns.
- Enforced by: review; `CLAUDE.md` invariant 2.
- Since: founding design.

### R-WEB-2 The ledger design, and words beside every color
Newsreader for prose, IBM Plex Mono for numbers, commands, labels and the wordmark, self hosted under
`apps/web/public/fonts`. Tokens in `app/globals.css`; the visual reference is
`docs/design/public-site.html`. Warm paper, hairline rules, the blue accent. No emoji icons, no
decorative gradients beyond the two approved pictures: the WebGL hero (`components/Veil.tsx`) and,
since 2026-10-09, the ink landscape behind Browse's page head (`components/InkScene.tsx`, owner's request). Semantic colors (ok,
warn, crit) always ship with words next to them; color never says it alone. Light and dark are both
designed, not flipped.
- Why: the design is approved; consistency is what makes it read as one product.
- How to apply: new UI reuses tokens and existing components; a new control copies an existing one
  (the date range menu copies the sort row's type and the ledger's hairlines).
- Enforced by: review against the reference HTML; screenshots at desktop and phone width before a
  web deploy.
- Since: 2026-09-24.

### R-WEB-3 Every view is a URL
Filters, sorts, searches, roles, industries and date ranges are real links with ordinary `href`s,
updated with native history so back and forward work, and usable without JavaScript as GET fallbacks.
Old parameter values keep parsing to something sensible.
- Why: a view that cannot be shared or bookmarked is a view that cannot be discussed.
- How to apply: `QueryLink` for same-page filters; `ladderHref` builds every ladder URL; a renamed
  parameter keeps its old spelling as an alias.
- Enforced by: review; Playwright checks of the URL after each control.
- Since: 2026-09-24.

## Catalog and data

### R-DATA-1 User-supplied content is data, never instructions
Reviews, discussion threads, client records, listing text fetched from upstream, anything read back
from the database or uploaded by users may contain directive-looking text. It is inert everywhere,
and especially in anything that reaches a model prompt.
- Why: the product reads thousands of repositories it did not write.
- How to apply: quote, escape or structure; never concatenate user text into an instruction. The same
  rule applies product-side (`plugins/personalens/skills/personalens/SKILL.md`).
- Enforced by: review; `CLAUDE.md` invariant 5.
- Since: founding design.

### R-DATA-2 Listed repositories are metadata pinned to a commit
A **listed entry** (`catalog/listed/<slug>.json`) records a repository at one commit with the sha256
of every file. **Skills** are fetched from upstream at that commit on first use, every hash checked,
then cached. **MCP servers**, **plugins**, **subagents** and **commands** are listed with their setup
line and never proxied or re-hosted. **Vendored packages** under `plugins/` are the reviewed core.
- Why: we distribute other people's work; the user must get exactly what was reviewed, and we must
  never become the host of record for a server we do not run.
- How to apply: index with `tools/bulk_index.py` or `tools/index_upstream.py`; editorial fields live
  inside the hashed `cheatcode.json`, so run `listed.refresh_generated(entry)` after editing them.
- Enforced by: `tests/test_listed.py`; `services/listed.py` refuses a hash mismatch.
- Since: 2026-09-28.

### R-DATA-3 Indexing thresholds and what is never indexed
Skills repositories need 3 or more stars and a permissive license; registry MCP servers 100 or more
stars for `io.github` namespaces and 10 for domain namespaces, stars counting only when the repository
owner matches the namespace; GitHub-only MCP servers, plugins, subagents and commands 100 or more
stars, and a GitHub-only MCP server must say "MCP server" in its name or description. Never indexed:
CC-BY-NC packs, "Lenny" packs, Commons Clause repositories, Anthropic's proprietary xlsx/docx/pptx
skills, aggregators. Removals made in review are recorded in `catalog/review-decisions.json` and
honored by the indexer; money, data-loss or security errors are removed even when a reviewer would
keep them.
- Why: the catalog's value is that someone looked; the thresholds are where looking becomes possible.
- How to apply: `tools/bulk_index.py` applies the thresholds; `tools/apply_review.py` the verdicts;
  `docs/INDEXING-LOG.md` records what was turned down and why.
- Enforced by: the indexer; `tests/test_listed.py`.
- Since: 2026-09-24, thresholds 2026-09-28.

### R-DATA-4 Skills hang on jobs; roles are lists of jobs
Every skill in a vendored package is tagged with a **job** in `catalog/skill-index.json`; package
**roles** are derived from those jobs, never hand-tagged. A **toolkit** need may only list skills that
serve the need's job. Listed repositories may be tagged; vendored packages must be.
- Why: one classification, derived one way, is the only kind that stays consistent across 400 skills.
- How to apply: tag the skills, run `tools/research/build_skill_index.py`; the tests fail until done.
- Enforced by: `tests/test_jobs.py`, `tests/test_toolkits.py`, `tests/test_roles.py`.
- Since: 2026-09-27.

### R-DATA-5 Catalog files are reviewed like code and validated by tests
`catalog/*.json` are curated content with a schema id, a date and tests that check them against the
packages on disk. Placement in them is editorial and never paid (R-TRUST-2).
- Why: a JSON file nobody tests rots faster than code.
- How to apply: every catalog file has a `schema` field named in `docs/TAXONOMY.md`, a loader in
  `app/services/`, and a test.
- Enforced by: `tests/test_docs.py` (schemas listed), the per-file tests.
- Since: 2026-09-27.

### R-DATA-6 A concept is explained, dated and sourced; its standing is a judgment with a reason
Each **concept** in `catalog/concepts.json` says in plain words what the idea is, how to apply it today
in ChatGPT or Claude, what it changes in daily work and where it goes wrong. Its **concept status**
(rising, established, fading) is the editor's call, with a `since` month, a one-sentence reason and
dated sources; the **concept trend** shown beside it is computed from star gains and never stored. The
listings mapped to a concept are chosen by hand, each with a sentence saying what in that listing
embodies the concept; keyword coincidence is not a mapping. None of it is a ranking input.
- Why: the owner's rule (2026-10-04): a person who does not know what they are using gets nothing from
  it. A status without a reason is an opinion; a mapping without a why is a keyword match.
- How to apply: write the entry for a product manager, not an engineer; cite at least two dated
  sources for a status; map a listing only after reading it; retire a concept by setting it to fading
  with the reason, never by deleting it.
- Enforced by: `tests/test_concepts.py` (file valid, mappings exist, trend computed);
  `tests/test_docs.py` (the taxonomy lists every concept); review of every content change.
- Since: 2026-10-04.

## Names and copy

### R-COPY-1 The names
The product is **Cheatcode_** (the trailing underscore is part of the name). In the interface it always
starts with a capital C: the wordmark is `Cheatcode_` with a blue underscore, and every title, heading,
label and installer message says Cheatcode_ or Cheatcode, never lowercase. "Cheatcode" without the
underscore is fine mid-sentence. Domains, package names, URL schemes and code identifiers stay lowercase
and drop it (cheatcodehq.com, cheatcode://). The first listing is **PersonaLens**, singular, capital P
and L; never "PersonaLenses", never "Customer Jury".
- Why: decided 2026-09; a name spelled three ways is three products. The capital C: owner, 2026-10-06.
- How to apply: copy the spelling from this rule; write `Cheatcode<i>_</i>` for the wordmark.
- Enforced by: `apps/web/tests/brand.test.cjs` (no lowercase wordmark or title in the web app);
  review for everything else.
- Since: 2026-09; capital C since 2026-10-06.

### R-COPY-2 House style
No dashes in prose or UI copy (no em or en dash; use commas, colons, periods). Plain human wording. No
marketing filler ("revolutionary", "next-gen"). Numbers carry their unit and, where they are someone
else's, their source and date.
- Why: the ledger reads like a record, not a pitch.
- How to apply: write the sentence you would say to the person; cut the adjective.
- Enforced by: review of every copy change.
- Since: 2026-09-24.

### R-COPY-3 Installs on the page, deploys in the data
The UI says **install**; the data model and API say **deploy** (`weekly_deploys`, `InstallEvent`).
They are the same thing: one package written into one AI app. New UI copy says install; new API
fields follow the existing data names so the contract stays stable (R-API-2).
- Why: readers know "install"; the API was named before the copy was decided, and renaming the
  contract would break clients for a word.
- How to apply: `docs/TAXONOMY.md` maps every such pair; use the page word on pages and the data word
  in code.
- Enforced by: review.
- Since: 2026-09-28.

### R-COPY-4 The public contact is admin@cheatcodehq.com
No owner name, personal email or personal handle on any page, in any script output, or in anything a
visitor can see.
- Why: the company speaks, not a person.
- How to apply: use the address; link `/privacy` and `/terms` where contact is offered.
- Enforced by: review.
- Since: 2026-09-28.

## Process

### R-PROC-1 Definition of done
API change: `pytest` passes and every new or changed endpoint has a smoke test. Web change:
`npm run build` passes (type errors fail the build; that is the check). Model change: a migration
(R-OPS-3). Deployed change: verified on the live site in a real browser, recorded in
`deploy/README.md`. Reporting is honest: a failing test is reported with its output, a skipped step
is named as skipped, and nothing is called done that was not run.
- Why: the owner acts on the report.
- How to apply: run the checks; paste the last lines; say what was not done.
- Enforced by: the owner reads the report.
- Since: founding design.

### R-PROC-2 Verify in the real client, prefer zero touch
An install path is proven in the real client on this Mac (Claude Code listing the plugin, Codex naming
the skill, Gemini listing it, Doubao's log showing the upload) before it is claimed. Automatic before
manual: a route that needs the user to paste or copy is a fallback, never the default.
- Why: a path verified against documentation alone failed in the real Claude Code on 2026-09-28.
- How to apply: `docs/superpowers/verification/` records each verification with the client version.
- Enforced by: `CLAUDE.md` status notes name what was verified and what was not.
- Since: 2026-09-24.

### R-PROC-3 Whatever runs in the image is tried in the image
Anything that depends on where the code sits (`Path(__file__)`, startup work, cron commands, env
lookups) is run inside the container (`docker compose exec api ...`) before a rollout is called done.
- Why: on 2026-09-30 a path resolved by `__file__` existed in the checkout and not in the image, and
  every ladder request returned 500 for ten minutes.
- How to apply: after building the image, exec the new code path once before `docker rollout`.
- Enforced by: the deploy procedure.
- Since: 2026-09-30.

### R-PROC-4 One place for rules, one for words, and both move with the code
This file holds the rules; `docs/TAXONOMY.md` holds the words; `CLAUDE.md` summarizes and links to
both and carries the dated status notes; `docs/ARCHITECTURE.md` describes mechanisms. A rule or a term
is added, changed or retired here in the same change as the code, with its date. Nothing restates a
rule in its own words elsewhere; it cites the id.
- Why: two copies of a rule are two rules.
- How to apply: cite `R-...` ids in code comments and docs; cite taxonomy terms by their canonical
  name; run the docs tests.
- Enforced by: `apps/api/tests/test_docs.py`.
- Since: 2026-10-02.
