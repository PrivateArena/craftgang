# CraftGang mirror sync

`craftgang.sh` keeps the **CraftGang** organisation an exact, up-to-date copy of
every repository of an upstream organisation (**storytold** by default): 65
repositories, all branches (artcraft alone has 1302) and all tags.

Nothing is downloaded to disk. GitHub's own servers do the work, which is why
multi-GB repos sync in seconds:

| step | GitHub API call | web equivalent |
| --- | --- | --- |
| create the copy | `POST /repos/{up}/{repo}/forks {organization:"CraftGang"}` | the **Fork** button |
| fast-forward a branch | `POST /repos/{org}/{repo}/merge-upstream {branch}` | the **Sync fork** button |
| hard-reset a branch | `PATCH /repos/{org}/{repo}/git/refs/heads/{branch} {force:true}` | server-side `git push --force` |
| add a branch/tag | `POST /repos/{org}/{repo}/git/refs` | server-side `git push` |

Only the default branch is compared by `verify`; `-a` compares every branch. Full
runs compare commit SHAs with 2 bulk calls per repo (`/branches` + `/tags` on both
sides) and issue per-ref calls only for refs that actually differ.

### Measured timings

65 repositories, nothing to change (2026-10-20, this machine):

| command | wall | API calls | before | where the time goes |
| --- | --- | --- | --- | --- |
| `status` | ~9 s | 16 | 157 s / 205 | org indexes + one batched ref snapshot |
| `verify` | ~10 s | 4 | 41 s / 133 | two GraphQL org queries carry every default branch head |
| `verify -a` | ~34 s | ~102 | - | snapshot, then per-repo paging for what it could not prove |
| `plan` / `sync` (no changes) | ~38 s | ~179 | 61 s / 368 | snapshot + tag listings and real per-ref work |
| `verify -r NAME` (single repo) | ~3.4 s | 4 | - | org index skipped below `index_min_repos` |

`parallel.write` was measured on this org: 47 s at width 4, 35 s at 6, 31 s at 8 and no
further gain at 12 - the remaining time is round-trip latency, not CPU (user + sys under
7 s). Going below that needs fewer calls, not more concurrency, which is what the ref
snapshot below is for. Wall time of the GraphQL phase moves with server load: 9-16 s for
`status` across repeated runs, and any repo whose snapshot query timed out is simply
re-checked per repo instead of failing the run.

## Requirements

* the token account must be able to create repositories in `CraftGang`
  (owner or admin member)
* token scopes: classic `repo,read:org`, or fine-grained
  *Administration RW, Contents RW, Pull requests RW*
* `curl`, `jq`, plus `git`/SSH only for the `mirror` fallback
* read access to `POST /graphql` - the mirror-side repo index (fork parent, default
  branch head) comes from one GraphQL query per 100 repositories, because the REST
  repository listing does not return `parent` at all

```bash
./craftgang.sh auth                      # identity, scopes, access to the target org
./craftgang.sh token ~/.config/gh/pat   # or: echo PAT | ./craftgang.sh token -
```

Token lookup order: `CRAFTGANG_TOKEN` → `GH_TOKEN`/`GITHUB_TOKEN` →
`.craftgang/token` → `./craftgang.token` → `gh auth token`.

## Configuration

Settings live in `config.json` next to the script, so nothing here is tied to one pair of
organisations: point `source_org` / `target_org` at any two GitHub owners (an org or a
plain user login both work) and the same script mirrors that instead.

```json
{ "source_org": "storytold", "target_org": "CraftGang", "dump_api_responses": false }
```

Precedence: **command line > environment > `config.json` > built-in default.**

```bash
./craftgang.sh config                       # exactly what is in use, and from which file
./craftgang.sh -c ~/mirrors/dsp.json status # a different mirror definition
```

| `config.json` key | env / flag override | default | meaning |
| --- | --- | --- | --- |
| `source_org` | `CRAFTGANG_SOURCE`, `--source` | - | owner mirrored **from** |
| `target_org` | `CRAFTGANG_TARGET`, `--target` | - | owner mirrored **into** |
| `api` | `CRAFTGANG_API` | `https://api.github.com` | REST + GraphQL base URL (works for GHES) |
| `git_host` | `CRAFTGANG_GIT_HOST` | `github.com` | ssh host used by `mirror` |
| `ssh_key` | `CRAFTGANG_SSH_KEY` | ssh agent / `~/.ssh/config` | explicit key for `mirror` only |
| `state_dir` | `CRAFTGANG_STATE` | `./.craftgang` | token, log, per-run index files |
| `parallel.read` | `CRAFTGANG_READ_PARALLEL` | `12` | repos in flight for `status`/`verify`/`plan` (GET only) |
| `parallel.write` | `CRAFTGANG_WRITE_PARALLEL` | `8` | repos in flight for `sync`/`mirror` |
| `parallel.all` | `CRAFTGANG_PARALLEL`, `-j` | - | force one width for every command |
| `fork_spacing` | `CRAFTGANG_FORK_SPACING` | `20` | seconds between fork creations |
| `fork_timeout` | `CRAFTGANG_FORK_TIMEOUT` | `900` | seconds to wait for a fork to appear |
| `ratelimit_max_wait` | `CRAFTGANG_RATELIMIT_WAIT` | `300` | max backoff when rate limited |
| `curl.connect_timeout` | `CRAFTGANG_CONNECT_TIMEOUT` | `10` | seconds |
| `curl.max_time` | `CRAFTGANG_MAX_TIME` | `60` | seconds |
| `dump_api_responses` | `CRAFTGANG_DUMP_API` | `false` | also write `body.*` / `headers.*` per API call, for debugging |
| `log_api_calls` | `CRAFTGANG_LOG_API` | `true` | append one line per API call to `.craftgang/craftgang.log` |
| `ref_snapshot` | `CRAFTGANG_REF_SNAPSHOT` | `true` | one batched GraphQL ref listing per 12 repos, instead of 4 paginated REST listings per repo |
| `ref_snapshot_chunk` | `CRAFTGANG_SNAP_CHUNK` | `12` | repositories per GraphQL request: 6 costs 26 calls, 12 costs 16, 20 costs 12 but each request is slower |
| `index_min_repos` | `CRAFTGANG_INDEX_MIN` | `8` | with `-r` for fewer repos than this, the two org-wide index queries are skipped - a single repo check costs ~3 s instead of ~10 s |

`dump_api_responses` is off by default because API responses are kept in shell
variables: a normal run writes **no** per-call files into the state directory at all
(`.craftgang/run/<pid>/` holds only the two index files for the run and is deleted on
exit). Enabling it costs about two file writes per API call (~270 per full `status`).

## Usage

```bash
./craftgang.sh plan                     # read-only report (no writes at all)
./craftgang.sh sync                     # create missing copies + update every branch and tag
./craftgang.sh status                   # missing / fork / branch coverage per repo
./craftgang.sh verify                   # compare default branches, exit 1 on drift
./craftgang.sh verify -a                # compare every branch (still 2 calls per repo)
./craftgang.sh sync -r artcraft         # single repo (repeat -r for more)
./craftgang.sh sync --force             # always hard-reset refs, skip merge commits
./craftgang.sh sync --prune             # also delete branches/tags that upstream removed
./craftgang.sh verify -a -j 8           # 8 repos in flight
./craftgang.sh config                    # resolved settings (config.json + env + defaults)
./craftgang.sh -c other.json sync        # mirror a different org pair
./craftgang.sh schedule 6h              # keep it fresh: cron entry  "0 */6 * * *"
./craftgang.sh schedule clear
```

`schedule`/`verify` are what makes "keep it up to date" a fire-and-forget job;
`verify` is cron/webhook friendly because it returns non-zero on drift.

## Design notes & limits

* **All branches, not just the default** — forks are created with
  `default_branch_only:false`, so a fresh copy already carries every branch.
* **Empty repositories cannot be forked** (`AniCraft` upstream has no commits).
  Reported as `empty`, skipped — 65/66 repos are mirrored because of this.
* **A branch whose commits the fork does not have** - created upstream after the fork,
  or rewritten by a force-push - cannot be created or reset by any API call, because
  GitHub answers `Not Found` for an object it does not have. The run reports
  `needs-mirror` and `./craftgang.sh mirror -r NAME` (git, uses ~100 MB disk at
  most, cached under `.craftgang/mirrors`) closes that last gap.
* **Fork creation is throttled** by GitHub; creations are serialised and spaced
  by `fork_spacing` (20 s default). Anything refused goes to
  `.craftgang/deferred` and is finished by the next run - only the first run is
  slow.
* **Diverged branches are repaired automatically**: `merge-upstream` is tried
  first (a real fast-forward), and if the mirror still differs from upstream the
  ref is force-reset server-side. This handles upstream force-pushes, e.g.
  Dependabot rewriting its own branches.
* `/git/refs/*` ignores `?page=`, so all bulk comparisons use the paginated
  `/branches` and `/tags` listings (`/git/refs` would loop forever there).
* A **branch count** is read from the `Link rel="last"` header of a `per_page=1`
  request, so a 1302 branch repo costs the same single call as a 1 branch repo.
  `status` normally does not even need that: a connection `totalCount` is exact even when
  the returned node list stops at GitHub's page limit of 100, so the ref snapshot answers
  the branch totals of every repo it covered.
* **The ref snapshot compares like the API does.** A repo counts as identical only when
  both sides reported the same ref set, the same totals, and the listing was not truncated;
  anything else (a repo missing from one side, a timed-out GraphQL alias, over 100 refs)
  falls back to the per-repo paginated comparison, which is slower but never guesses.
* **The query builder stays inside awk.** `jaq` (a drop-in `jq` on some machines) has no
  `[inputs]`, no `$ARGS.positional` and no `array[a:b]`, and `jq` reads `a // {} as $x | ...`
  as `a // ({} as $x | ...)`, which silently returns a whole object instead of rows. The name
  chunks are therefore cut with awk and every `// ... as $x` is parenthesised, so one code
  path runs on both.
* `.craftgang/drift.tsv` columns are `repo`, `branch`, `mirror head` - the third field is
  what the mirror holds (`missing`, `unreadable`, `source-listing-failed`), never the
  upstream value, so a row is always a statement about the mirror.
* **`--prune` never trusts an unreadable listing.** An earlier version compared a bare
  ref name against `ref<TAB>sha` lines, which can never match, so `--prune` deleted
  every mirrored branch; it also treated a failed listing as an empty one. Both are
  guarded now: a failed or empty upstream map aborts the prune for that repo.
* **Read-only commands** (`status`, `verify`, `plan`) run 12 repositories at once; the
  write path uses 8, which is where the latency plateau was measured. `POST`/`PATCH`/
  `DELETE` count against GitHub's per-minute write points (which
  `X-RateLimit-Remaining` does not expose), so lower `parallel.write` towards 4 if a run
  ever starts reporting 403s.
* API responses are kept in shell variables, not files: a normal run creates nothing per
  call. Only the two index files live in `.craftgang/run/<pid>/` (deleted on exit), so a
  manual `status` can no longer wipe the in-flight responses of a scheduled `sync` -
  which used to turn a live listing into an empty one. `dump_api_responses` re-enables
  per-call `body.*`/`headers.*` files when a raw response has to be inspected.
* Tags are copied by ref and annotated tag objects are preserved.
* Concurrent runs are refused (`.craftgang/lock`); rate limits are honoured with
  backoff on `Retry-After` / `x-ratelimit-reset`.
* State, logs and the token live in `.craftgang/` (git-ignored).
