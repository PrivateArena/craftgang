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

Every run: 2 bulk calls per repo (`/branches` + `/tags` on both sides) to
compare commit SHAs, and per-ref calls only for refs that actually differ.
Measured full-organisation cost: **sync 36 s, verify 26 s**, ~350 API requests.

## Requirements

* the token account must be able to create repositories in `CraftGang`
  (owner or admin member)
* token scopes: classic `repo,read:org`, or fine-grained
  *Administration RW, Contents RW, Pull requests RW*
* `curl`, `jq`, plus `git`/SSH only for the `mirror` fallback

```bash
./craftgang.sh auth                      # identity, scopes, access to the target org
./craftgang.sh token ~/.config/gh/pat   # or: echo PAT | ./craftgang.sh token -
```

Token lookup order: `CRAFTGANG_TOKEN` → `GH_TOKEN`/`GITHUB_TOKEN` →
`.craftgang/token` → `./craftgang.token` → `gh auth token`.

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
* **A branch created upstream *after* the fork** may reference objects that do
  not exist in the fork, so no API call can create it. The run reports
  `needs-mirror` and `./craftgang.sh mirror -r NAME` (git, uses ~100 MB disk at
  most, cached under `.craftgang/mirrors`) closes that last gap.
* **Fork creation is throttled** by GitHub; creations are serialised and spaced
  by `CRAFTGANG_FORK_SPACING` (20 s default). Anything refused goes to
  `.craftgang/deferred` and is finished by the next run - only the first run is
  slow.
* **Diverged branches are repaired automatically**: `merge-upstream` is tried
  first (a real fast-forward), and if the mirror still differs from upstream the
  ref is force-reset server-side. This handles upstream force-pushes, e.g.
  Dependabot rewriting its own branches.
* `/git/refs/*` ignores `?page=`, so all bulk comparisons use the paginated
  `/branches` and `/tags` listings (`/git/refs` would loop forever there).
* Tags are copied by ref and annotated tag objects are preserved.
* Concurrent runs are refused (`.craftgang/lock`); rate limits are honoured with
  backoff on `Retry-After` / `x-ratelimit-reset`.
* State, logs and the token live in `.craftgang/` (git-ignored).

## Environment overrides

| variable | default | meaning |
| --- | --- | --- |
| `CRAFTGANG_SOURCE` | `storytold` | upstream org |
| `CRAFTGANG_TARGET` | `CraftGang` | destination org (a user login also works) |
| `CRAFTGANG_PARALLEL` | `4` | repositories processed at once |
| `CRAFTGANG_FORK_SPACING` | `20` | seconds between fork creations |
| `CRAFTGANG_FORK_TIMEOUT` | `900` | seconds to wait for a fork to appear |
| `CRAFTGANG_RATELIMIT_WAIT` | `300` | max backoff on rate limits |
| `CRAFTGANG_SSH_KEY` | `~/.ssh/id_ed25519_GunGunGun` | key used by `mirror` |
| `CRAFTGANG_GIT_HOST` | `github.com` | git host for `mirror` |
| `CRAFTGANG_STATE` | `./.craftgang` | state directory |
