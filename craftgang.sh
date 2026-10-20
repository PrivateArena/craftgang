#!/usr/bin/env bash
# craftgang.sh - mirror every repository of an upstream GitHub org into CraftGang.
#
# Default mode is DISKLESS: only GitHub REST calls (create a fork, then the
# server-side "Sync fork" / force ref update). No repository bytes are ever
# downloaded to this machine - the same thing as clicking Fork on github.com.
#
#   ./craftgang.sh auth                 # who is the token, may it write to CraftGang
#   ./craftgang.sh plan                 # read-only report of what is missing / stale
#   ./craftgang.sh sync                 # fork missing repos, sync branches + tags
#   ./craftgang.sh sync -r artcraft     # one repo only
#   ./craftgang.sh verify               # exit non-zero on drift (cron friendly)
#   ./craftgang.sh schedule 6h          # keep it fresh automatically
set -uo pipefail

# ------------------------------- configuration ----------------------------
# Everything in this block is a fallback. Real settings belong in config.json next to
# the script (or -c FILE / $CRAFTGANG_CONFIG), so the tool stays a generic "mirror one
# GitHub owner into another" script instead of being tied to a single pair of orgs.
# Precedence: command line  >  environment  >  config.json  >  built-in default.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${CRAFTGANG_CONFIG:-$SCRIPT_DIR/config.json}
CONFIG_EXPLICIT=${CRAFTGANG_CONFIG:+1}
CFG_JSON=''
SEP=$'\037'                              # field separator for repo rows (tab would collapse empties)
API_STATUS=0
CMD=sync DRY=0 FORCE=0 PRUNE=0 TAGS=1 SKIP_ARCH=0 JSON_OUT=0 QUIET=0 ALLOW_DISK=0 KEEP_MIRRORS=1 HELP=0
declare -a ONLY=() EXCL=()
CLI_SOURCE='' CLI_TARGET='' CLI_PARALLEL=''

cfg_get() { # cfg_get dotted.key -> string form of that config.json value, empty if unset
  [[ -n $CFG_JSON ]] || return 0
  jq -r --arg p "$1" 'getpath($p | split(".")) as $v
    | if $v == null then "" elif ($v | type) == "string" then $v else ($v | tostring) end' <<<"$CFG_JSON" 2>/dev/null
}

resolve() { # resolve CLI_VALUE ENV_NAME CONFIG_KEY DEFAULT -> first source that sets it
  local v=$1
  [[ -n $v ]] || v=${!2:-}
  [[ -n $v ]] || v=$(cfg_get "$3")
  printf '%s\n' "${v:-$4}"
}

yes_no() { [[ ${1,,} =~ ^(1|true|yes|on)$ ]] && echo 1 || echo 0; }

load_config() {
  if [[ -f $CONFIG_FILE ]]; then
    CFG_JSON=$(<"$CONFIG_FILE")
    jq -e . <<<"$CFG_JSON" >/dev/null 2>&1 || die "config: $CONFIG_FILE is not valid JSON"
  elif [[ -n $CONFIG_EXPLICIT ]]; then
    die "no such config file: $CONFIG_FILE"
  fi
  return 0
}

state_path() { # keep relative config paths next to the script, so cron gets them too
  case $1 in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$SCRIPT_DIR" "$1" ;;
  esac
}

configure() { # resolve settings, then build everything that depends on them
  load_config
  SOURCE_ORG=$(resolve "$CLI_SOURCE" CRAFTGANG_SOURCE source_org '')
  TARGET_ORG=$(resolve "$CLI_TARGET" CRAFTGANG_TARGET target_org '')
  [[ -n $SOURCE_ORG && -n $TARGET_ORG ]] || die "source_org and target_org are not set.
  Put them in $CONFIG_FILE (see --help), or pass --source/--target."
  API=$(resolve '' CRAFTGANG_API api https://api.github.com)
  GIT_HOST=$(resolve '' CRAFTGANG_GIT_HOST git_host github.com)
  SSH_KEY=$(resolve '' CRAFTGANG_SSH_KEY ssh_key '')   # empty = let ssh pick from the agent/config
  STATE_DIR=$(state_path "$(resolve '' CRAFTGANG_STATE state_dir "$SCRIPT_DIR/.craftgang")")
  LOG_FILE=$STATE_DIR/craftgang.log
  READ_PARALLEL=$(resolve '' CRAFTGANG_READ_PARALLEL parallel.read 12)
  WRITE_PARALLEL=$(resolve '' CRAFTGANG_WRITE_PARALLEL parallel.write 4)
  PARALLEL=$(resolve "$CLI_PARALLEL" CRAFTGANG_PARALLEL parallel.all '')   # set = same width for every command
  FORK_TIMEOUT=$(resolve '' CRAFTGANG_FORK_TIMEOUT fork_timeout 900)
  FORK_SPACING=$(resolve '' CRAFTGANG_FORK_SPACING fork_spacing 20)
  RL_MAX_SLEEP=$(resolve '' CRAFTGANG_RATELIMIT_WAIT ratelimit_max_wait 300)
  CURL_CONNECT_TIMEOUT=$(resolve '' CRAFTGANG_CONNECT_TIMEOUT curl.connect_timeout 10)
  CURL_MAX_TIME=$(resolve '' CRAFTGANG_MAX_TIME curl.max_time 60)
  # responses stay in shell variables; files are only written when explicitly asked for
  DUMP_API=$(yes_no "$(resolve '' CRAFTGANG_DUMP_API dump_api_responses 0)")
  LOG_API=$(yes_no "$(resolve '' CRAFTGANG_LOG_API log_api_calls 1)")
  # prefetch all branch/tag maps in a few batched GraphQL calls instead of 4 REST calls per repo
  REF_SNAPSHOT=$(yes_no "$(resolve '' CRAFTGANG_REF_SNAPSHOT ref_snapshot 1)")
  SNAP_CHUNK=$(resolve '' CRAFTGANG_SNAP_CHUNK ref_snapshot_chunk 15)
  case $CMD in status|verify|plan) [[ -n ${PARALLEL:-} ]] || PARALLEL=$READ_PARALLEL ;;
                  *)               [[ -n ${PARALLEL:-} ]] || PARALLEL=$WRITE_PARALLEL ;; esac
  mkdir -p "$STATE_DIR/mirrors" "$STATE_DIR/run"
  # One temp directory per invocation. The old global `rm -f $STATE_DIR/body.*` at startup
  # let a manual `status` delete a running cron `sync`'s in-flight API responses.
  RUN_DIR=$STATE_DIR/run/$$
  TARGET_INDEX=$RUN_DIR/target.tsv SOURCE_INDEX=$RUN_DIR/source.tsv
  HAVE_INDEX=0 HAVE_SNAPSHOT=0
  mkdir -p "$RUN_DIR"
  trap 'rm -rf "${RUN_DIR:?}"' EXIT
  find "$STATE_DIR/run" -mindepth 1 -maxdepth 1 -type d -mmin +180 -exec rm -rf {} + 2>/dev/null || :
  return 0
}

# ---------------------------------- output --------------------------------
bold=$'\e[1m' dim=$'\e[2m' red=$'\e[31m' grn=$'\e[32m' ylw=$'\e[33m' blu=$'\e[34m' off=$'\e[0m'
[[ -t 1 ]] || { bold= dim= red= grn= ylw= blu= off=; }

log()  { printf '%s %s\n' "$(date -u '+%F %T')" "$*" >>"$LOG_FILE"; }
say()  { [[ $QUIET == 1 ]] || printf '%b\n' "$*"; }
warn() { printf '%b\n' "${ylw}warn${off}  $*" >&2; }
die()  { printf '%b\n' "${red}error${off} $*" >&2; exit 1; }

usage() {
  cat <<'TXT'
craftgang.sh - keep CraftGang an exact mirror of an upstream GitHub org

TXT
  cat <<EOF
${bold}Commands${off}
  sync                fork missing repos, then sync every branch and tag   (default)
  plan                same as sync, changes nothing
  status              per-repo table: missing / fork / branch coverage
  verify              compare branch SHAs with upstream, exit 1 on drift (default branch;
                      -a compares every branch)     
  config              show the resolved configuration (config.json + env + defaults)
  mirror              disk fallback (git clone --mirror + push --mirror) for repos
                      GitHub refuses to fork (archived, fork-count limits)
  auth                show token identity, scopes and access to $TARGET_ORG
  token [FILE|-]      save the PAT used for $TARGET_ORG ("show" to inspect)
  schedule [INTERVAL] install/remove cron sync (6h default, "clear" removes)
  clean               delete temporary on-disk bare mirrors

${bold}Options${off}
  -r, --repo NAME        only this repo (repeatable)
  -x, --exclude NAME     skip this repo (repeatable)
  -j, --parallel N       concurrent API jobs (default: $READ_PARALLEL for status/verify/plan, $WRITE_PARALLEL for sync/mirror)
  -f, --force            hard-reset branch refs to upstream SHA instead of merging
      --prune            delete refs in $TARGET_ORG that upstream removed
      --no-tags          do not mirror tags
      --skip-archived    leave archived upstream repos alone
      --json             machine readable output (status)
  -q, --quiet            log only
      --keep-disk        allow "mirror" to run over every repo (needs disk)
  -K, --no-keep          delete the cached bare mirror after pushing
  -c, --config FILE      settings file (default: config.json next to the script)
      --source ORG       upstream org        (default $SOURCE_ORG)
      --target ORG       destination org/user (default $TARGET_ORG)
  -h, --help             this text
EOF
}

# --------------------------------- parsing --------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    sync|plan|status|verify|mirror|auth|clean|config) CMD=$1 ;;
    token|schedule)  CMD=$1; shift; CMD_ARG=${1:-}; continue ;;
    -r|--repo)    ONLY+=("$2"); shift ;;
    -x|--exclude) EXCL+=("$2"); shift ;;
    -j|--parallel) CLI_PARALLEL=$2; shift ;;
    -f|--force)   FORCE=1 ;;
    --prune)      PRUNE=1 ;;
    --no-tags)    TAGS=0 ;;
    --skip-archived) SKIP_ARCH=1 ;;
    --json)       JSON_OUT=1 ;;
    -a|--all)     ALL=all ;;
    -q|--quiet)   QUIET=1 ;;
    --keep-disk)  ALLOW_DISK=1 ;;
    -K|--no-keep) KEEP_MIRRORS=0 ;;
    -c|--config)  CONFIG_FILE=$2 CONFIG_EXPLICIT=1; shift ;;
    --source)     CLI_SOURCE=$2; shift ;;
    --target)     CLI_TARGET=$2; shift ;;
    -n|--dry-run) DRY=1; CMD=plan ;;
    -h|--help)    HELP=1 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
CMD_ARG=${CMD_ARG:-}
configure
(( HELP )) && { usage; exit 0; }

# ------------------------------------ HTTP --------------------------------
J() { [[ -n ${RESP_BODY:-} ]] || return 1; jq -r "$1" <<<"$RESP_BODY" 2>/dev/null; }

jqb() { jq "$@" <<<"$RESP_BODY"; }   # jq over the body of the last api_raw call

# Responses are kept in shell variables: nothing is written to .craftgang per call
# unless dump_api_responses is turned on. One curl -D - -o - stream carries the header
# block, a blank line, then the body, so no temp file and no -w marker is needed.
api_raw() { # api_raw METHOD PATH [JSON] -> API_STATUS, body in $RESP_BODY, headers in $RESP_HDR
  local method=$1 path=$2 data=${3:-} raw code attempt wait
  local args
  RESP_BODY='' RESP_HDR=''
  for attempt in 1 2 3 4; do
    args=(-sS -D - -o - -X "$method"
          --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME"
          -H "Authorization: Bearer $TOKEN"
          -H "Accept: application/vnd.github+json"
          -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n $data ]] && args+=(-H "Content-Type: application/json" --data "$data")
    raw=$(curl "${args[@]}" "$API$path" 2>>"$LOG_FILE") || {
      # transport failure: back off, but never on the last attempt (that 12 s bought nothing)
      (( attempt < 4 )) && sleep $((attempt * 3)); continue; }
    RESP_HDR=${raw%%$'\r\n\r\n'*}
    RESP_BODY=${raw#*$'\r\n\r\n'}
    [[ ${#RESP_BODY} -ge ${#raw} ]] && RESP_BODY=''          # no header/body separator at all
    code=$(awk '$1 ~ /^HTTP\// { c = $2 } END { print c + 0 }' <<<"$RESP_HDR")
    API_STATUS=$code
    if (( DUMP_API )); then                                  # diagnostics only; readers use the variables
      printf '%s' "$RESP_BODY" >"$RUN_DIR/body.$BASHPID"
      printf '%s' "$RESP_HDR" >"$RUN_DIR/headers.$BASHPID"
    fi
    # only genuine rate limits are retried here - other 4xx are real answers
    if [[ $code == 429 || $code == 403 ]] && grep -qi 'rate limit\|abuse detection' <<<"$RESP_BODY"; then
      wait=$(awk 'tolower($1)=="retry-after:"{gsub(/\r/,"",$2); print $2}' <<<"$RESP_HDR")
      [[ -z $wait ]] && wait=$(awk -v now="$(date +%s)" 'tolower($1)=="x-ratelimit-reset:"{gsub(/\r/,"",$2); d=$2-now; print (d>0?d:1)}' <<<"$RESP_HDR")
      : "${wait:=60}"; (( wait > RL_MAX_SLEEP )) && wait=$RL_MAX_SLEEP
      (( attempt < 4 )) || break          # do not sleep 300 s just to return a failure
      warn "rate limited on $method $path - sleeping ${wait}s"
      sleep "$wait"; continue
    fi
    (( LOG_API )) && log "$code $method $path"
    return 0
  done
  return 1
}

# ----------------------------------- auth ---------------------------------
load_token() {
  [[ -n ${TOKEN:-} ]] && return 0
  TOKEN=${CRAFTGANG_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}
  [[ -n $TOKEN ]] && { TOKEN_SRC=env; return 0; }
  local f
  for f in "$STATE_DIR/token" "$SCRIPT_DIR/craftgang.token" "$HOME/.config/craftgang/token"; do
    [[ -s $f ]] && { TOKEN=$(tr -d ' \t\r\n' <"$f"); TOKEN_SRC=$f; return 0; }
  done
  command -v gh >/dev/null 2>&1 && TOKEN=$(gh auth token 2>/dev/null)
  [[ -n $TOKEN ]] && { TOKEN_SRC="gh CLI"; return 0; }
  die "no GitHub token available.
  A token is needed because creating/forking repositories in $TARGET_ORG is a
  server side API call. It must belong to an account that may create repos in
  $TARGET_ORG (classic scopes: repo,read:org - fine-grained: Administration RW,
  Contents RW, Pull requests RW). Then:
      ./craftgang.sh token <pat-file>        # or: echo PAT | ./craftgang.sh token -"
}

cmd_auth() {
  load_token
  api_raw GET /user || die "cannot reach $API"
  [[ $API_STATUS == 200 ]] || die "token from $TOKEN_SRC rejected (HTTP $API_STATUS): $(J .message)"
  local me; me=$(J .login)
  say "identity   : ${bold}$me${off}  ${dim}($TOKEN_SRC, $(J .type))${off}"
  say "scopes     : $(grep -i '^x-oauth-scopes:' <<<"$RESP_HDR" | cut -d' ' -f2- | tr -d '\r')"
  api_raw GET "/orgs/$TARGET_ORG/members/$me"
  case $API_STATUS in
    204) say "target     : ${grn}$TARGET_ORG - member${off}" ;;
    404) say "target     : ${red}$TARGET_ORG - not a member, cannot fork/create there${off}" ;;
    *)   say "target     : ${red}$TARGET_ORG - HTTP $API_STATUS${off}" ;;
  esac
  api_raw GET "/orgs/$TARGET_ORG"
  [[ $API_STATUS == 200 ]] && say "           : $(J .login), $(J .public_repos) public repos visible"
  api_raw GET "/orgs/$SOURCE_ORG"
  [[ $API_STATUS == 200 ]] && say "source     : ${bold}$(J .login)${off} - $(J .public_repos) public repos"
  say "write test : ${dim}POST /repos/$SOURCE_ORG/<repo>/forks{organization:$TARGET_ORG}${off}"
}

# -------------------------------- discovery -------------------------------
source_repos() { # name<TAB>archived<TAB>fork<TAB>parent<TAB>default<TAB>private<TAB>size_kb
  local page=1 n path="/orgs/$SOURCE_ORG/repos?type=all&sort=full_name"
  while :; do
    api_raw GET "$path&per_page=100&page=$page" || return 1
    if [[ $API_STATUS == 404 && $page == 1 && $path == /orgs/* ]]; then
      path="/users/$SOURCE_ORG/repos?type=owner&sort=full_name"   # a plain user login, not an org
      api_raw GET "$path&per_page=100&page=1" || return 1
    fi
    [[ $API_STATUS == 200 ]] || { warn "list $SOURCE_ORG: HTTP $API_STATUS $(J .message)"; return 1; }
    n=$(jqb 'length')
    [[ ${n:-0} == 0 ]] && break
    jqb -r --arg s "$SEP" '.[] | [.name,(.archived|tostring),(.fork|tostring),(.parent.full_name // ""),.default_branch,(.private|tostring),(.size|tostring)] | join($s)'
    [[ $n -lt 100 ]] && break
    page=$((page + 1))
  done
  return 0
}

selected() {
  local name=$1 hit r e
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    hit=0
    for r in "${ONLY[@]}"; do [[ $r == "$name" ]] && hit=1; done
    [[ $hit == 1 ]] || return 1
  fi
  for e in "${EXCL[@]:-}"; do [[ -n $e && $e == "$name" ]] && return 1; done
  return 0
}

target_rows() {
  local name rest
  while IFS=$SEP read -r name rest; do
    [[ -n ${name:-} ]] && selected "$name" && printf '%s%s%s\n' "$name" "$SEP" "$rest"
  done < <(source_repos)
  return 0
}

# ---------------------------- repo side operations ------------------------
target_state() { # NAME -> none | fork:<parent> | plain | http<code>
  local row parent
  if [[ ${HAVE_INDEX:-0} == 1 ]]; then          # answered from the index, no per-repo GET
    row=$(awk -F'\t' -v n="$1" '$1 == n { print $2 "\t" $3; exit }' "$TARGET_INDEX")
    if [[ -n $row ]]; then
      if [[ ${row%%$'\t'*} == true ]]; then
        parent=${row#*$'\t'}; echo "fork:$parent"
      else echo plain; fi
      return 0
    fi
    # Absent from the listing. A listing can lag or omit a repo the token can still
    # reach, and answering "none" here would let sync fork over it - confirm with one GET.
  fi
  api_raw GET "/repos/$TARGET_ORG/$1"
  case $API_STATUS in
    404) echo none ;;
    200) [[ $(J .fork) == true ]] && echo "fork:$(J .parent.full_name)" || echo plain ;;
    *)   echo "http$API_STATUS" ;;
  esac
}

# One GraphQL page lists 100 repos with their fork parent and default branch head.
# REST cannot do this: /orgs/{org}/repos does not return the `parent` field at all (only
# the single-repo GET does) and never carries head SHAs, which is what forced one or two
# API calls per repository before. Both sides of every comparison come from the same
# source, so no REST/GraphQL SHA semantics are ever mixed.
REPO_INDEX_QUERY='query($owner:String!,$cursor:String){repositoryOwner(login:$owner){repositories(first:100,after:$cursor,ownerAffiliations:[OWNER,COLLABORATOR,ORGANIZATION_MEMBER]){pageInfo{hasNextPage endCursor}nodes{name isFork parent{__typename ... on Repository{nameWithOwner}}defaultBranchRef{name target{oid}}}}}}'

build_repo_index() { # ORG FILE -> name<TAB>isFork<TAB>parent<TAB>defBranch<TAB>defOid, ~1 call / 100 repos
  local owner=$1 file=$2 cursor=''
  : >"$file"
  while :; do
    api_raw POST "/graphql" "$(jq -nc --arg q "$REPO_INDEX_QUERY" --arg o "$owner" --arg c "$cursor" \
               '{query:$q,variables:{owner:$o,cursor:(if $c == "" then null else $c end)}}')" || break
    [[ $API_STATUS == 200 ]] || { warn "$owner index: HTTP $API_STATUS $(J .message)"; break; }
    (( $(jqb -r 'if .errors then (.errors | length) else 0 end') )) && { warn "$owner index: $(J .errors[0].message)"; break; }
    [[ $(jqb -r '.data.repositoryOwner == null') == true ]] && { warn "$owner is not visible to this token"; break; }
    jqb -r '.data.repositoryOwner.repositories.nodes[]
      | [.name,(.isFork|tostring),(.parent.nameWithOwner // "-"),
         (.defaultBranchRef.name // "-"),(.defaultBranchRef.target.oid // "-")] | @tsv' >>"$file"
    [[ $(jqb -r '.data.repositoryOwner.repositories.pageInfo.hasNextPage') == true ]] || break
    cursor=$(jqb -r '.data.repositoryOwner.repositories.pageInfo.endCursor // ""')
    [[ -n $cursor ]] || break
  done
  [[ -s $file ]]
}

build_target_index() { # index $TARGET_ORG so state lookups need no per-repo GET
  if build_repo_index "$TARGET_ORG" "$TARGET_INDEX"; then
    HAVE_INDEX=1
  else
    rm -f "$TARGET_INDEX"                       # never let a half written index answer lookups
    warn "indexing $TARGET_ORG failed - per-repo lookups"
  fi
  return 0
}

build_snapshot() { # index both sides -> default branch heads compare without any per-repo call
  if build_repo_index "$SOURCE_ORG" "$SOURCE_INDEX" && build_repo_index "$TARGET_ORG" "$TARGET_INDEX"; then
    HAVE_INDEX=1 HAVE_SNAPSHOT=1
  else
    rm -f "$TARGET_INDEX" "$SOURCE_INDEX"
    warn "no default-branch snapshot for $SOURCE_ORG - comparing repositories one by one"
  fi
  return 0
}

index_head() { # FILE NAME BRANCH -> head sha of BRANCH, rc 1 when the index cannot answer exactly
  local row
  row=$(awk -F'\t' -v n="$2" -v b="$3" '$1 == n && $4 == b { print $5; exit }' "$1")
  [[ -n $row && $row != - ]] || return 1
  printf '%s\n' "$row"
}

create_fork() { # NAME -> 0 ok, 2 refused, 3 deferred (rate limited)
  local name=$1 payload waited=0
  payload=$(jq -nc --arg o "$TARGET_ORG" --arg n "$name" '{organization:$o,name:$n,default_branch_only:false}')
  if [[ $DRY == 1 ]]; then emit "  ${blu}fork${off}       $name ${dim}(would create)${off}"; return 0; fi
  fork_throttle
  api_raw POST "/repos/$SOURCE_ORG/$name/forks" "$payload"
  case $API_STATUS in
    201|202) ;;
    422) emit "  ${red}refused${off}    $name - $(J .message)"; return 2 ;;
    403|429)
      if grep -qi 'empty repositor\|no git content' <<<"$RESP_BODY"; then
        emit "  ${dim}empty${off}      $name ${dim}(upstream has no commits - nothing to mirror)${off}"; return 4
      fi
      if grep -qi 'rate limit\|abuse' <<<"$RESP_BODY"; then
        note_deferred "$name"; emit "  ${ylw}deferred${off}   $name ${dim}fork throttled - next run will retry${off}"; return 3
      fi
      emit "  ${red}refused${off}    $name - $(J .message)"; return 2 ;;
    *) emit "  ${red}failed${off}     $name - HTTP $API_STATUS $(J .message)"; return 2 ;;
  esac
  local poll
  while (( waited < FORK_TIMEOUT )); do
    poll=3; (( waited < 15 )) && poll=1          # most forks are ready in a couple of seconds
    sleep "$poll"; waited=$((waited + poll))
    api_raw GET "/repos/$TARGET_ORG/$name"
    [[ $API_STATUS == 200 ]] || continue
    # visible is not the same as populated: refs must actually have been copied across,
    # otherwise the branch/tag sync below runs against an empty fork
    api_raw GET "/repos/$TARGET_ORG/$name/branches?per_page=1"
    [[ $API_STATUS == 200 && $(jqb 'length') != 0 ]] && { emit "  ${grn}created${off}    $name ${dim}${waited}s${off}"; return 0; }
  done
  warn "fork $name not visible after ${FORK_TIMEOUT}s"
  note_deferred "$name"
  return 3
}

# GitHub throttles fork creation (secondary rate limit), so creations are
# serialised across the parallel workers and spaced out.
fork_throttle() {
  if command -v flock >/dev/null 2>&1; then
    # The wait must happen in a subshell: with `exec 8>` in the calling shell the lock was
    # held until that sync_one job finished, i.e. through the readiness poll and the whole
    # branch/tag sync, so spacing became max(20 s, entire repo sync) instead of 20 s.
    ( flock 8 || exit 0; fork_gap ) 8>"$STATE_DIR/fork.lock"
  else
    fork_gap
  fi
  return 0
}

fork_gap() { # honour FORK_SPACING, then record this creation time
  local last now wait
  last=$(cat "$STATE_DIR/lastfork" 2>/dev/null || echo 0)
  now=$(date +%s); wait=$(( last + FORK_SPACING - now ))
  (( wait > 0 )) && sleep "$wait"
  date +%s >"$STATE_DIR/lastfork"
  return 0
}

note_deferred() { # remember repos that still need work, for the closing summary
  local f=$STATE_DIR/deferred
  [[ -f $f ]] && grep -qxF "$1" "$f" || echo "$1" >>"$f"
}

count_branches() { # ORG NAME -> branch count in ONE call (per_page=1 + Link rel="last")
  local org=$1 name=$2 last
  api_raw GET "/repos/$org/$name/branches?per_page=1" || return 1
  case $API_STATUS in
    404) echo 0; return 0 ;;                 # repo not there yet - counted as zero, not as an error
    200) : ;;
    *) return 1 ;;
  esac
  # at per_page=1 the last page number *is* the item count, so a 370 branch repo
  # (vectorcraft) costs the same single tiny call as a 1 branch repo
  last=$(tr -d '\r' <<<"$RESP_HDR" | sed -n 's/.*[?&]page=\([0-9]*\)>; rel="last".*/\1/p' | head -1)
  [[ -n $last ]] && { echo "$last"; return 0; }
  jqb 'length'
  return 0
}
# NOTE: /git/refs/* ignores ?page= (it keeps returning the first page), so the
# paginated /branches and /tags listings are used for all bulk ref comparisons.
ref_map() { # ref_map ORG NAME -> "refs/heads/<name><TAB>sha" for every branch
  # A failed listing returns 1: an empty map from a 403 would otherwise be read as
  # "upstream has no branches", which means "create every ref" or "prune every ref".
  local org=$1 name=$2 page=1 n
  while :; do
    api_raw GET "/repos/$org/$name/branches?per_page=100&page=$page" || return 1
    [[ $API_STATUS == 200 ]] || { warn "$org/$name branches: HTTP $API_STATUS $(J .message)"; return 1; }
    n=$(jqb 'length')
    [[ ${n:-0} == 0 ]] && break
    jqb -r --arg p "refs/heads/" '.[] | [$p + .name, .commit.sha] | @tsv'
    [[ $n -lt 100 ]] && break
    page=$((page + 1))
  done
  return 0
}

tag_map() { # tag_map ORG NAME -> "refs/tags/<name><TAB>commit sha"
  local org=$1 name=$2 page=1 n
  while :; do
    api_raw GET "/repos/$org/$name/tags?per_page=100&page=$page" || return 1
    [[ $API_STATUS == 200 ]] || { warn "$org/$name tags: HTTP $API_STATUS $(J .message)"; return 1; }
    n=$(jqb 'length')
    [[ ${n:-0} == 0 ]] && break
    jqb -r --arg p "refs/tags/" '.[] | [$p + .name, .commit.sha] | @tsv'
    [[ $n -lt 100 ]] && break
    page=$((page + 1))
  done
  return 0
}

sha_of() { # sha_of MAPFILE REFNAME -> sha
  awk -F'\t' -v r="$2" '$1 == r { print $2; exit }' "$1"
}

head_sha() { # ORG NAME BRANCH -> head sha of a single branch (1 tiny call, rc 3 = branch absent)
  api_raw GET "/repos/$1/$2/git/ref/heads/$(enc "$3")" || return 1
  case $API_STATUS in
    200) J '.object.sha' ;;
    404) return 3 ;;
    *)   return 1 ;;
  esac
}

target_sha() { head_sha "$TARGET_ORG" "$1" "$2"; }
upstream_sha() { head_sha "$SOURCE_ORG" "$1" "$2"; }
enc() { jq -rn --arg s "$1" '$s|@uri'; }

create_ref() { # NAME REF SHA -> branch exists upstream but not in the mirror yet
  local name=$1 ref=$2 sha=$3
  [[ $DRY == 1 ]] && { echo "would-create-ref"; return; }
  api_raw POST "/repos/$TARGET_ORG/$name/git/refs" "$(jq -nc --arg r "$ref" --arg s "$sha" '{ref:$r,sha:$s}')"
  if [[ $API_STATUS == 201 ]]; then echo "created-ref:${sha:0:7}"
  else echo "needs-mirror:new branch $ref is not reachable in the fork -> ./craftgang.sh mirror -r $name"; fi
}

merge_upstream() { # NAME BRANCH -> "synced|upto-date|conflict:<msg>"
  local name=$1 branch=$2 msg
  [[ $DRY == 1 ]] && { echo "would-sync"; return; }
  api_raw POST "/repos/$TARGET_ORG/$name/merge-upstream" "$(jq -nc --arg b "$branch" '{branch:$b}')"
  case $API_STATUS in
    200) msg=$(J .message)
         [[ $msg == *"not behind"* ]] && echo not-behind || echo synced ;;
    204) echo upto-date ;;
    404) echo gone ;;
    *)   echo "conflict:$(J .message)" ;;
  esac
}

sync_branches() { # NAME -> branch<TAB>action<TAB>note   (2 bulk calls when nothing changed)
  local name=$1 ref sha tsha act branch
  local up=$RUN_DIR/up.$name.tmp tp=$RUN_DIR/dst.$name.tmp
  ref_map "$SOURCE_ORG" "$name" >"$up" || {
    printf '%s\t%s\t%s\n' '-' list-failed "upstream branches: HTTP $API_STATUS"; return 1; }
  ref_map "$TARGET_ORG" "$name" >"$tp" || {
    printf '%s\t%s\t%s\n' '-' list-failed "mirror branches: HTTP $API_STATUS"; return 1; }
  while IFS=$'\t' read -r ref sha; do
    [[ -z ${ref:-} ]] && continue
    branch=${ref#refs/heads/}
    tsha=$(sha_of "$tp" "$ref")
    if [[ -z ${sha:-} ]]; then
      continue
    elif [[ -z $tsha ]]; then
      act=$(create_ref "$name" "$ref" "$sha")
    elif [[ $tsha == "$sha" ]]; then
      act=upto-date
    elif [[ $FORCE == 1 ]]; then
      act=$(force_sha "$name" "$ref" "$sha" "$tsha")
    else
      act=$(merge_upstream "$name" "$branch")
      # a mirror must match exactly: fast-forward if possible, hard reset otherwise
      tsha=$(target_sha "$name" "$branch")
      if [[ $tsha != "$sha" ]]; then
        act="$(force_sha "$name" "$ref" "$sha" "$tsha") ${dim}(after ${act%%:*})${off}"
      fi
    fi
    printf '%s\t%s\t%s\n' "$branch" "${act%%:*}" "${act#*:}"
  done <"$up"
  [[ $PRUNE == 1 ]] || rm -f "$up" "$tp"   # --prune reuses these maps instead of re-fetching them
  return 0
}

force_sha() { # NAME REF UP_SHA CUR_SHA -> hard reset (or create) the mirror ref
  local name=$1 ref=$2 sha=$3 cur=$4
  [[ $DRY == 1 ]] && { echo "would-force"; return; }
  if [[ -z $cur ]]; then echo "$(create_ref "$name" "$ref" "$sha")"; return; fi
  api_raw PATCH "/repos/$TARGET_ORG/$name/git/refs/${ref#refs/}" "$(jq -nc --arg s "$sha" '{sha:$s,force:true}')"
  case $API_STATUS in
    200) echo "forced:${cur:0:7}->${sha:0:7}" ;;
    # GitHub answers "Not Found" when the target commit is not reachable in the fork, so
    # the objects still have to be pushed over git - no API call can create them
    404) echo "needs-mirror:$ref" ;;
    *)   echo "force-failed:$(J .message)" ;;
  esac
}


sync_tags() { # NAME -> tag<TAB>action<TAB>sha  (bulk compare, then add/update what differs)
  local name=$1 ref sha tsha page=1
  local up=$RUN_DIR/tup.$name.tmp tp=$RUN_DIR/tdst.$name.tmp
  tag_map "$SOURCE_ORG" "$name" >"$up" || {
    printf '%s\t%s\t%s\n' '-' tag-list-failed "upstream tags: HTTP $API_STATUS"; return 1; }
  if [[ -s $up ]]; then                     # only look at the mirror when there is something to copy
    tag_map "$TARGET_ORG" "$name" >"$tp" || {
      printf '%s\t%s\t%s\n' '-' tag-list-failed "mirror tags: HTTP $API_STATUS"; return 1; }
  else
    : >"$tp"
  fi
  while IFS=$'\t' read -r ref sha; do
    [[ -z ${ref:-} ]] && continue
    tsha=$(sha_of "$tp" "$ref")
    [[ -n $tsha && $tsha == "$sha" ]] && continue
    # prefer the annotated tag object so annotations survive the copy
    local obj=$sha
    api_raw GET "/repos/$SOURCE_ORG/$name/git/ref/${ref#refs/}"
    [[ $API_STATUS == 200 && $(J .object.type) == tag ]] && obj=$(J .object.sha)
    if [[ $DRY == 1 ]]; then printf '%s\twould-tag\t%s\n' "${ref#refs/tags/}" "${obj:0:7}"; continue; fi
    if [[ -z $tsha ]]; then
      api_raw POST "/repos/$TARGET_ORG/$name/git/refs" "$(jq -nc --arg r "$ref" --arg s "$obj" '{ref:$r,sha:$s}')"
    else
      api_raw PATCH "/repos/$TARGET_ORG/$name/git/refs/${ref#refs/}" "$(jq -nc --arg s "$obj" '{sha:$s,force:true}')"
    fi
    case $API_STATUS in
      200|201) printf '%s\t%s\t%s\n' "${ref#refs/tags/}" "$( [[ $API_STATUS == 201 ]] && echo tagged || echo retagged )" "${obj:0:7}" ;;
      *)       printf '%s\ttag-failed\t%s\n' "${ref#refs/tags/}" "$(J .message)" ;;
    esac
  done <"$up"
  [[ $PRUNE == 1 ]] || rm -f "$up" "$tp"
  return 0
}

prune_refs() { # NAME heads|tags -> delete mirror refs upstream no longer has
  local name=$1 kind=$2 up tp fetched=0 ref doomed
  if [[ $kind == heads ]]; then
    up=$RUN_DIR/up.$name.tmp; tp=$RUN_DIR/dst.$name.tmp
  else
    up=$RUN_DIR/tup.$name.tmp; tp=$RUN_DIR/tdst.$name.tmp
  fi
  if [[ -s $up && -f $tp ]]; then           # reuse the bulk maps sync_branches / sync_tags just made
    fetched=0
  else
    fetched=1
    if [[ $kind == heads ]]; then
      ref_map "$SOURCE_ORG" "$name" >"$up" && ref_map "$TARGET_ORG" "$name" >"$tp" || fetched=0
    else
      tag_map "$SOURCE_ORG" "$name" >"$up" && tag_map "$TARGET_ORG" "$name" >"$tp" || fetched=0
    fi
    # NEVER prune against a failed listing: an unreadable upstream map used to mean
    # "delete every ref in the mirror"
    if (( ! fetched )); then
      warn "$name: upstream $kind listing failed - prune skipped"
      return 1
    fi
  fi
  doomed=$RUN_DIR/prune.$name.$kind.tmp
  if [[ -s $up ]]; then
    # ref, not the whole "ref<TAB>sha" line - matching the line made -x never fire
    awk -F'\t' 'NR == FNR { keep[$1]; next } !($1 in keep) { print $1 }' "$up" "$tp" >"$doomed"
  else
    cut -f1 "$tp" >"$doomed"                # upstream has no $kind at all -> every mirror ref is extra
  fi
  while IFS= read -r ref; do
    [[ -z $ref ]] && continue
    if [[ $DRY == 1 ]]; then emit "  ${ylw}prune${off}      $name:${ref#refs/} ${dim}(would delete)${off}"; continue; fi
    api_raw DELETE "/repos/$TARGET_ORG/$name/git/refs/${ref#refs/}"
    [[ $API_STATUS == 204 ]] && emit "  ${ylw}pruned${off}     $name:${ref#refs/}"
  done <"$doomed"
  rm -f "$doomed"
  (( fetched )) && rm -f "$up" "$tp"
  return 0
}

# ------------------------------ one repository ----------------------------
BUF=""                                   # per-repo output buffer, flushed atomically
emit() { BUF+="$(printf '%b\n' "$*")"$'\n'; }
flush() { [[ -n $BUF ]] && printf '%s' "$BUF"; BUF=""; }

sync_one() { # one row from source_repos
  local name archived isfork parent def priv size st rc
  IFS=$SEP read -r name archived isfork parent def priv size <<<"$1"
  st=$(target_state "$name")
  case $st in
    none)
      if [[ $archived == true && $SKIP_ARCH == 1 ]]; then
        emit "  ${ylw}skip${off}       $name ${dim}(archived upstream)${off}"; flush; return 0
      fi
      create_fork "$name"; rc=$?
      if (( rc == 0 )); then
        st=fork:"$SOURCE_ORG/$name"
      else
        case $rc in
          3) emit "  ${ylw}deferred${off}   $name ${dim}picked up by the next run${off}"; flush; return 3 ;;
          4) flush; return 0 ;;
          *) emit "  ${ylw}mirror${off}      $name ${dim}fork refused -> ./craftgang.sh mirror -r $name${off}"; flush; return 2 ;;
        esac
      fi ;;
    http*) emit "  ${red}error${off}      $name - $st"; flush; return 1 ;;
    plain) emit "  ${dim}plain repo${off}   $name - refs pushed server side" ;;
  esac
  local b act note n=0 up=0 cur=0 bad=0 need_mirror=0
  while IFS=$'\t' read -r b act note; do
    [[ -z ${b:-} ]] && continue
    n=$((n + 1))
    [[ $act == needs-mirror ]] && need_mirror=1
    case $act in
      synced|forced|would-sync|would-force) up=$((up + 1)); emit "    ${grn}$act${off} ${b} ${dim}${note}${off}" ;;
      upto-date) cur=$((cur + 1)) ;;
      *) bad=$((bad + 1)); emit "    ${red}$act${off} ${b} ${dim}${note}${off}" ;;
    esac
  done <<<"$(sync_branches "$name")"
  emit "  ${grn}ok${off}         $name ${dim}${n} branches | ${up} updated | ${cur} current${off}"
  if (( bad )); then
    (( need_mirror )) && emit "  ${ylw}needs-mirror${off} $name ${bad} branch(es) need a git push: ./craftgang.sh mirror -r $name" \
                      || emit "  ${red}stale${off}      $name ${bad} branch(es) need --force or manual review"
  fi

  if [[ $TAGS == 1 ]]; then
    local t a s
    while IFS=$'\t' read -r t a s; do [[ -n ${t:-} ]] && emit "    ${grn}$a${off} $t ${dim}${s}${off}"; done <<<"$(sync_tags "$name")"
  fi
  if [[ $PRUNE == 1 ]]; then prune_refs "$name" heads; prune_refs "$name" tags; fi
  flush
  return 0
}

run_pool() { # run_pool FUNC  <one TSV row per line on stdin  (rolling window)
  local fn=$1 line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do wait -n || true; done
    "$fn" "$line" &
  done
  wait
  return 0
}

single_run_guard() { # refuse two concurrent runs (they would fight over refs)
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$STATE_DIR/lock" || return 0
  flock -n 9 || die "another craftgang.sh run is still going ($STATE_DIR/lock)"
}

# --------------------------------- commands -------------------------------
cmd_sync() {
  load_token
  single_run_guard
  build_target_index
  local rows total
  rows=$(target_rows) || die "cannot list $SOURCE_ORG"
  total=$(grep -c . <<<"$rows")
  say "${bold}$SOURCE_ORG${off}  ->  ${bold}$TARGET_ORG${off}   $total repositories   ${dim}server side, nothing on disk${off}"
  [[ $DRY == 1 ]] && say "${ylw}dry run - no changes${off}"
  : >"$STATE_DIR/deferred"
  printf '%s\n' "$rows" | run_pool sync_one
  say ""
  if [[ -s $STATE_DIR/deferred ]]; then
    say "${ylw}deferred (fork rate limit), run again to finish:${off} $(tr '\n' ' ' <"$STATE_DIR/deferred")"
    [[ $DRY == 1 ]] || rm -f "$STATE_DIR/deferred"
  fi
  say "finished ${dim}$(date -u '+%F %T UTC') - log: $LOG_FILE${off}"
}

status_one() { # one row -> "state<TAB>na<TAB>nb<TAB>note" in $RUN_DIR/status.<name> (ordered by cmd_status)
  local name archived isfork parent def priv size st na nb state note rc=0
  IFS=$SEP read -r name archived isfork parent def priv size <<<"$1"
  st=$(target_state "$name")
  nb=$(count_branches "$SOURCE_ORG" "$name") || { nb='?'; rc=1; }
  na=$(count_branches "$TARGET_ORG" "$name") || { na='?'; rc=1; }
  state=${st%%:*}
  case $state in
    fork)  if [[ $st == fork:"$SOURCE_ORG/$name" ]]; then note="upstream=$SOURCE_ORG"
           elif [[ $st == fork:- ]]; then state=fork; note="parent not visible"
           else note="wrong parent ${st#fork:}"; fi ;;
    plain) note="plain repo - refs pushed server side" ;;
    none)  note="not mirrored yet" ;;
    error) state=error; note="${st#error}" ;;
    *)     state=error; note="$st" ;;
  esac
  # a failed count is never silently printed as 0 - that would look like "nothing to mirror"
  if (( rc )) && [[ $state != error ]]; then state=error; note="branch count failed (HTTP $API_STATUS)"; fi
  printf '%s\t%s\t%s\t%s\n' "$state" "$na" "$nb" "$note" >"$RUN_DIR/status.$name"
  return 0
}

cmd_status() {
  load_token
  build_target_index
  local rows name rest archived isfork parent def priv size state counts note nb na first=1 f
  rows=$(target_rows) || die "cannot list $SOURCE_ORG"
  printf '%s\n' "$rows" | run_pool status_one      # was a serial loop: same calls as verify, 4x slower
  if [[ $JSON_OUT == 1 ]]; then printf '['
  else printf '%-44s %-8s %-9s %s\n' "${bold}REPO${off}" "${bold}STATE${off}" "${bold}BRANCHES${off}" "${bold}NOTE${off}"; fi
  while IFS=$SEP read -r name archived isfork parent def priv size; do    # printed in listing order
    [[ -z ${name:-} ]] && continue
    f=$RUN_DIR/status.$name
    if [[ -f $f ]]; then
      IFS=$'\t' read -r state na nb note <"$f"
    else
      state=error na='?' nb='?' note="worker produced no result"
    fi
    if [[ $JSON_OUT == 1 ]]; then
      [[ $first == 1 ]] && first=0 || printf ','
      [[ $nb =~ ^[0-9]+$ ]] || nb=0
      [[ $na =~ ^[0-9]+$ ]] || na=0
      jq -nc --arg n "$name" --arg s "$state" --arg p "$parent" --arg a "$archived" \
        --argjson nb "$nb" --argjson na "$na" \
        '{repo:$n,state:$s,upstream:$p,archived:($a=="true"),up_branches:$nb,mirrored_branches:$na}'
    else
      case $note in
        upstream=*) ;;                                       # the normal, healthy line
        "wrong parent"*) note="${red}$note${off}" ;;
        *) note="${dim}$note${off}" ;;
      esac
      printf '%-44s %-8s %-9s %s\n' "$name" "$state" "$na/$nb" "$note"
    fi
  done <<<"$rows"
  [[ $JSON_OUT == 1 ]] && printf ']'
  return 0
}

cmd_verify() {
  load_token
  single_run_guard
  if [[ -z ${ALL:-} ]]; then
    build_snapshot                              # default branches: 2 GraphQL calls replace 132 REST calls
  else
    build_target_index
  fi
  local rows; rows=$(target_rows)
  : >"$STATE_DIR/drift.tsv"
  say "${bold}$SOURCE_ORG${off} vs ${bold}$TARGET_ORG${off} - comparing ${ALL:-default branches}${ALL:+ of every branch}   ${dim}drift list: $STATE_DIR/drift.tsv${off}"
  printf '%s\n' "$rows" | run_pool verify_one
  local drift; drift=$(wc -l <"$STATE_DIR/drift.tsv")
  if (( drift )); then warn "$drift branch(es) differ from $SOURCE_ORG"; exit 1; fi
  say "${grn}in sync${off} - every compared branch is byte-identical by commit SHA"
}

verify_one() { # one row -> compares branch head SHAs (2 calls per repo, 4 with -a)
  local name archived isfork parent def priv size st n=0 bad=0 ref sha tsha up tp
  IFS=$SEP read -r name archived isfork parent def priv size <<<"$1"
  up=$STATE_DIR/vup.$name.tmp; tp=$STATE_DIR/vdst.$name.tmp
  st=$(target_state "$name")
  if [[ $st == none ]]; then
    if [[ $archived == true || ${size:-0} == 0 ]]; then
      emit "  ${dim}empty${off}      $name ${dim}(upstream has no content)${off}"; flush; return 0
    fi
    printf '%s\t%s\t%s\n' "$name" "-" "missing" >>"$STATE_DIR/drift.tsv"
    emit "  ${red}missing${off}    $name"; flush; return 1
  fi
  # default-branch mode (no -a): one head per side, nothing paginated, so a 370 branch
  # repo costs exactly the same as a 1 branch repo.
  if [[ -z ${ALL:-} && -n ${def:-} ]]; then
    local rc=0
    if [[ ${HAVE_SNAPSHOT:-0} == 1 ]] && sha=$(index_head "$SOURCE_INDEX" "$name" "$def"); then
      tsha=$(index_head "$TARGET_INDEX" "$name" "$def") || tsha=''    # no row = no branch on the mirror
    else
      # snapshot cannot answer (or is unavailable): two single-ref REST reads for this repo
      sha=$(head_sha "$SOURCE_ORG" "$name" "$def") || rc=$?
      if (( rc )); then
        if (( rc == 3 )) && [[ $archived == true || ${size:-0} == 0 ]]; then
          emit "  ${dim}empty${off}      $name ${dim}(no commits upstream)${off}"; flush; return 0
        fi
        printf '%s\t%s\t%s\n' "$name" "$def" "unreadable" >>"$STATE_DIR/drift.tsv"   # counts as drift, never as "in sync"
        emit "  ${red}error${off}      $name upstream $def unreadable (HTTP $API_STATUS)"; flush; return 1
      fi
      rc=0
      tsha=$(head_sha "$TARGET_ORG" "$name" "$def") || rc=$?
      if (( rc && rc != 3 )); then
        printf '%s\t%s\t%s\n' "$name" "$def" "unreadable" >>"$STATE_DIR/drift.tsv"
        emit "  ${red}error${off}      $name mirror $def unreadable (HTTP $API_STATUS)"; flush; return 1
      fi
      [[ $rc == 3 ]] && tsha=''                 # branch absent on the mirror
    fi
    n=1
    if [[ -n $tsha && $tsha == "$sha" ]]; then
      emit "  ${grn}ok${off}         $name ${dim}1 branch identical${off}"
    else
      bad=1
      printf '%s\t%s\t%s\n' "$name" "$def" "${tsha:-missing}" >>"$STATE_DIR/drift.tsv"
      emit "  ${red}drift${off}      $name $def ${dim}${tsha:-missing} != ${sha:0:7}${off}"
      emit "  ${red}stale${off}      $name 1/1 branch differs - run: sync -r $name"
    fi
    flush
    (( bad )) && return 1
    return 0
  fi
  # -a: compare every branch, which needs the full listings
  ref_map "$SOURCE_ORG" "$name" >"$up" || {
    printf '%s\t%s\t%s\n' "$name" "*" "source-listing-failed" >>"$STATE_DIR/drift.tsv"
    emit "  ${red}error${off}      $name upstream branch listing failed"; flush; return 1; }
  ref_map "$TARGET_ORG" "$name" >"$tp" || {
    printf '%s\t%s\t%s\n' "$name" "*" "target-listing-failed" >>"$STATE_DIR/drift.tsv"
    emit "  ${red}error${off}      $name mirror branch listing failed"; flush; return 1; }
  while IFS=$'\t' read -r ref sha; do
    [[ -z ${ref:-} ]] && continue
    n=$((n + 1))
    tsha=$(sha_of "$tp" "$ref")
    [[ -n $tsha && $tsha == "$sha" ]] && continue
    bad=$((bad + 1))
    printf '%s\t%s\t%s\n' "$name" "${ref#refs/heads/}" "${tsha:-missing}" >>"$STATE_DIR/drift.tsv"
    emit "  ${red}drift${off}      $name ${ref#refs/heads/} ${dim}${tsha:-missing} != ${sha:0:7}${off}"
  done <"$up"
  if (( bad )); then emit "  ${red}stale${off}      $name ${bad}/${n} branch(es) differ - run: sync -r $name"
  else emit "  ${grn}ok${off}         $name ${dim}${n} branch(es) identical${off}"; fi
  rm -f "$up" "$tp"
  flush
  return 0
}

mirror_repo() { # disk fallback for what the API cannot do (new objects, >fork limits)
  local name=$1 dir=$STATE_DIR/mirrors/$name.git url=git@$GIT_HOST:$TARGET_ORG/$name.git
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes$( [[ -n $SSH_KEY ]] && printf ' -i %s -o IdentitiesOnly=yes' "$SSH_KEY" )"
  if [[ -d $dir ]]; then
    say "  ${blu}update${off} $name ${dim}(incremental fetch)${off}"
    git -C "$dir" remote update --prune >/dev/null || { warn "fetch $name failed"; return 1; }
  else
    say "  ${blu}clone${off}  $name ${dim}(bare mirror cached in $STATE_DIR/mirrors)${off}"
    git clone --quiet --mirror "git@$GIT_HOST:$SOURCE_ORG/$name.git" "$dir" || { warn "clone $name failed"; return 1; }
  fi
  [[ $DRY == 1 ]] && { say "  ${blu}push${off}     $name ${dim}(dry)${off}"; return 0; }
  say "  ${blu}push${off}   $name"
  # explicit refspecs: --mirror would also try to push refs/pull/*, which GitHub rejects
  git -C "$dir" push --quiet --force --prune "$url" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' \
    || { warn "push $name failed"; return 1; }
  say "  ${grn}pushed${off} $name"
  [[ $KEEP_MIRRORS == 0 ]] && { rm -rf "$dir"; say "  ${dim}dropped cached mirror${off}"; }
  return 0
}

cmd_mirror() {
  load_token
  local rows name rest
  rows=$(target_rows)
  if [[ ${#ONLY[@]} == 0 && $ALLOW_DISK == 0 ]]; then
    say "mirror copies objects through git, so it needs scratch disk."
    say "restrict it with -r NAME, or pass --keep-disk to mirror everything."
    exit 2
  fi
  while IFS=$SEP read -r name rest; do [[ -n ${name:-} ]] && mirror_repo "$name"; done <<<"$rows"
}

cmd_config() {
  printf '%-20s %s\n' "${bold}setting${off}" "${bold}value${off}"
  printf '%-20s %s\n' 'config file' "${CONFIG_FILE}$( [[ -f $CONFIG_FILE ]] || printf '  (absent - env and defaults in use)')"
  printf '%-20s %s\n' 'source_org' "$SOURCE_ORG"
  printf '%-20s %s\n' 'target_org' "$TARGET_ORG"
  printf '%-20s %s\n' 'api' "$API"
  printf '%-20s %s\n' 'git_host' "$GIT_HOST"
  printf '%-20s %s\n' 'ssh_key' "${SSH_KEY:-<ssh agent / ~/.ssh/config>}"
  printf '%-20s %s\n' 'state_dir' "$STATE_DIR"
  printf '%-20s %s\n' 'parallel.read' "$READ_PARALLEL"
  printf '%-20s %s\n' 'parallel.write' "$WRITE_PARALLEL"
  printf '%-20s %s\n' 'this command' "$PARALLEL concurrent repositories"
  printf '%-20s %s\n' 'fork_spacing' "$FORK_SPACING"
  printf '%-20s %s\n' 'fork_timeout' "$FORK_TIMEOUT"
  printf '%-20s %s\n' 'ratelimit_max_wait' "$RL_MAX_SLEEP"
  printf '%-20s %s\n' 'curl timeouts' "connect ${CURL_CONNECT_TIMEOUT}s, total ${CURL_MAX_TIME}s"
  printf '%-20s %s\n' 'dump_api_responses' "$( (( DUMP_API )) && echo 'on -> files under run/<pid>/' || echo 'off (responses kept in memory)' )"
  printf '%-20s %s\n' 'log_api_calls' "$( (( LOG_API )) && echo "on -> $LOG_FILE" || echo off )"
  return 0
}

cmd_token() {
  local src=${CMD_ARG:-} tok
  if [[ -z $src || $src == show ]]; then
    if [[ -s $STATE_DIR/token ]]; then echo "stored: $STATE_DIR/token"
    else echo "no stored token - falling back to GH_TOKEN / gh CLI"; fi
    return 0
  fi
  if [[ $src == - ]]; then tok=$(tr -d ' \t\r\n'); else tok=$(tr -d ' \t\r\n' <"$src"); fi
  [[ -n $tok ]] || die "empty token"
  printf '%s' "$tok" >"$STATE_DIR/token"
  chmod 600 "$STATE_DIR/token"
  say "saved token -> $STATE_DIR/token"
  unset TOKEN; cmd_auth
}

cmd_schedule() {
  local every=${CMD_ARG:-6h} expr
  if [[ $every == clear ]]; then
    (crontab -l 2>/dev/null | grep -v 'craftgang-sync') | crontab -
    say "cron entry removed"; return 0
  fi
  case $every in
    daily) expr="0 7 * * *" ;;
    *h)    expr="0 */${every%h} * * *" ;;
    *)     die "interval must look like 6h or daily" ;;
  esac
  local line="$expr cd $SCRIPT_DIR && ./craftgang.sh sync -q >>$STATE_DIR/cron.log 2>&1  # craftgang-sync"
  { crontab -l 2>/dev/null | grep -v 'craftgang-sync'; echo "$line"; } | crontab -
  say "installed cron ${bold}$expr${off} -> $SCRIPT_DIR/craftgang.sh sync"
}

# ----------------------------------- main ---------------------------------
case $CMD in
  help)     usage ;;
  sync)     cmd_sync ;;
  plan)     DRY=1; cmd_sync ;;
  status)   cmd_status ;;
  config)   cmd_config ;;
  verify)   cmd_verify ;;
  mirror)   cmd_mirror ;;
  auth)     cmd_auth ;;
  token)    cmd_token ;;
  schedule) cmd_schedule ;;
  clean)    rm -rf "$STATE_DIR/mirrors"; mkdir -p "$STATE_DIR/mirrors"; say "removed on-disk mirrors" ;;
esac
