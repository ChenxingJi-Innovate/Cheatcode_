# The Cheatcode_ package format

One directory per installable listing. This is what "Install" distributes: the Cheatcode_ API reads these
directories, serves them as verified archives, and renders the installer and a Claude Code marketplace from them.
The three packages in [../packages](../packages) are complete examples.

## Layout (Agent Plugins convention, Agent Skills standard)

```
<slug>/
  cheatcode.json              identity + provenance; this file is what makes it a Cheatcode package
  .claude-plugin/plugin.json  Claude Code manifest, name must equal <slug>
  LICENSE                     verbatim license (upstream's for indexed packages)
  skills/<name>/SKILL.md      one folder per skill; frontmatter name must equal the folder name
  ...                         anything else upstream ships (shared/, references/, commands/)
```

`cheatcode.json` fields: `schema` (`cheatcode-package/v1`), `slug`, `name`, `version`, `tagline`,
`description`, `category`, `license`, `publisher {name, url, verified}`, `homepage`, `upstream`
(`null` for native packages, else `{repo, url, commit, pushed_at, fetched_at, stars}`), `skills`,
`excluded`.

The API validates every package on load; an invalid package fails the test suite rather than being served half-broken.

## Two kinds of package

- **native**: written and published here. `upstream` is null, publisher is verified.
  Examples: the three packages in this repository.
- **indexed**: a public repository packaged at one pinned commit by the indexer.
  Upstream's license ships verbatim, the commit is recorded, and files over 100 KB (images) are
  left out and listed under `excluded`. The listing says "Indexed · open source" and "not yet
  claimed by its author".

Indexed packages get no seeded numbers, no reviews and no certification. They start at zero.

## What install does with a package

The installer (the Mac app, or `GET /install.sh` for the terminal) downloads `archive.tar.gz`, checks the
sha256 the API publishes, then copies:

- Claude Code and GLM: the whole package to `~/.claude/skills/<slug>/`, which Claude Code loads as
  the plugin `<slug>@skills-dir` (skills become `/<slug>:<skill>`).
- Every other client: each `skills/<name>/` to `<client skills dir>/<name>/` (flat, the layout every
  client documents), with LICENSE and the package's shared files under `<dir>/.cheatcode/<slug>/`.
- 豆包 Doubao: each `skills/<name>/` (with the LICENSE copied inside) to the app's watched
  `.user_skills/` folder; the app uploads it into the account. Removal is done in the app. The
  console also offers one zip per skill (`skills/<name>.zip`) for manual upload.

A receipt at `<dir>/.cheatcode/<slug>.receipt` records the install id and every path written, so
`--uninstall` removes exactly those and closes the same install event.

## Compliance checklist before indexing a repository

Run through this for every upstream repo; the indexer enforces the first three, the rest are
judgment calls recorded in the listing's `cheatcode.json` (`flags`, if any) and the PR description.

1. **License file exists** upstream and is permissive: MIT, Apache-2.0, BSD-2/3, ISC, MPL-2.0,
   CC-BY-4.0. Not indexed: no license, "all rights reserved", GPL/AGPL/LGPL, CC-NC or CC-ND,
   custom "see license" texts. Apache-2.0 repos keep their NOTICE file (the indexer copies
   everything the plugin root ships except git metadata and files over 100 KB).
2. **Pinned commit and attribution**: `upstream.commit` is a full sha, the publisher is the
   upstream owner, the listing says "Indexed · open source" and "not yet claimed by its author".
   New upstream releases are re-indexed on purpose, never synced from HEAD.
3. **License travels with the files**: `LICENSE` sits at the package root, inside every Claude
   Code plugin install, next to the skills for flat installs, and inside each skill folder for
   clients that upload the folder (Doubao).
4. **No brand or trademark in the listing name or slug** (consulting firms, certification bodies,
   product names used as if endorsed). Upstream skill folder names are kept as they are; the
   listing name and tagline are ours and stay neutral.
5. **No content that looks lifted from paid material**: whole chapters of books, course
   handouts, paywalled newsletters, or proprietary frameworks reproduced verbatim. Summaries and
   original method write-ups are fine.
6. **No instructions that break a site's terms**: scraping behind logins, evading rate limits,
   or collecting personal data. Skills that call a vendor API are fine when the vendor is named
   and the key is the user's.
7. **Runs without secrets by default**, or the listing says which service and key it needs.
8. **Prompt-injection posture**: SKILL.md treats user files and web content as data. Flag
   skills that instruct the agent to follow instructions found in fetched pages.

