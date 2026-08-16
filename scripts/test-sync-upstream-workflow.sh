#!/usr/bin/env bash
# Exercise the upstream-sync workflow against disposable local Git repositories.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STEPS="$WORK/steps"
BIN="$WORK/bin"
mkdir -p "$STEPS" "$BIN"

step_count="$(awk -v output="$STEPS" '
  function finish() {
    if (file != "") {
      close(file)
      file = ""
    }
  }
  /^        run: \|$/ {
    finish()
    block++
    file = output "/" block ".sh"
    print "set -euo pipefail" > file
    next
  }
  file != "" && /^          / {
    line = $0
    sub(/^          /, "", line)
    print line >> file
    next
  }
  file != "" && /^$/ {
    print "" >> file
    next
  }
  { finish() }
  END {
    finish()
    print block
  }
' "$ROOT/.github/workflows/sync-upstream.yml")"
if [[ "$step_count" != 5 ]]; then
  echo "expected five workflow shell steps, found $step_count" >&2
  exit 1
fi

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

operation="${1:-} ${2:-}"
shift 2
base=""
head=""
while (( $# > 0 )); do
  case "$1" in
    --base)
      base="$2"
      shift 2
      ;;
    --head)
      head="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "$operation" in
  "pr list")
    printf 'list\t%s\t%s\n' "$base" "$head" >> "$GH_STATE_DIR/calls"
    case "$head" in
      upstream-sync) cat "$GH_STATE_DIR/open-upstream" ;;
      linux-port-sync) cat "$GH_STATE_DIR/open-linux" ;;
      *) printf '0\n' ;;
    esac
    ;;
  "pr create")
    printf 'create\t%s\t%s\n' "$base" "$head" >> "$GH_STATE_DIR/calls"
    ;;
  *)
    echo "unexpected gh operation: $operation" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$BIN/gh"

fail() {
  echo "upstream-sync workflow test failed: $*" >&2
  exit 1
}

assert_ref() {
  local expected="$1"
  local repository="$2"
  local reference="$3"
  local actual
  actual="$(git --git-dir="$repository" rev-parse "$reference")"
  [[ "$actual" == "$expected" ]] || fail "$reference is $actual, expected $expected"
}

assert_call() {
  local expected="$1"
  grep -Fqx "$expected" "$CALLS" || fail "missing gh call: $expected"
}

prepare_fixture() {
  local name="$1"
  local open_upstream="$2"
  local open_linux="$3"

  SCENARIO="$WORK/$name"
  ORIGIN="$SCENARIO/origin.git"
  UPSTREAM="$SCENARIO/upstream.git"
  SEED="$SCENARIO/seed"
  CHECKOUT="$SCENARIO/checkout"
  STATE="$SCENARIO/state"
  CALLS="$STATE/calls"
  mkdir -p "$SCENARIO" "$STATE"
  : > "$CALLS"
  printf '%s\n' "$open_upstream" > "$STATE/open-upstream"
  printf '%s\n' "$open_linux" > "$STATE/open-linux"

  git init --bare -q "$ORIGIN"
  git init --bare -q "$UPSTREAM"
  git init -q "$SEED"
  git -C "$SEED" config user.name "Sync Workflow Test"
  git -C "$SEED" config user.email "sync-workflow@example.invalid"

  git -C "$SEED" switch -q -c master
  printf 'root\n' > "$SEED/root.txt"
  git -C "$SEED" add root.txt
  git -C "$SEED" commit -q -m root
  ROOT_SHA="$(git -C "$SEED" rev-parse HEAD)"
  printf 'master\n' > "$SEED/master.txt"
  git -C "$SEED" add master.txt
  git -C "$SEED" commit -q -m "master update"
  MASTER_SHA="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" remote add origin "$ORIGIN"
  git -C "$SEED" push -q origin master

  git -C "$SEED" switch -q -c linux-port "$ROOT_SHA"
  printf 'linux\n' > "$SEED/linux.txt"
  git -C "$SEED" add linux.txt
  git -C "$SEED" commit -q -m "linux change"
  git -C "$SEED" push -q origin linux-port

  git -C "$SEED" switch -q master
  printf 'upstream\n' > "$SEED/upstream.txt"
  git -C "$SEED" add upstream.txt
  git -C "$SEED" commit -q -m "upstream update"
  UPSTREAM_SHA="$(git -C "$SEED" rev-parse HEAD)"
  git -C "$SEED" remote add upstream "$UPSTREAM"
  git -C "$SEED" push -q upstream HEAD:master

  UPSTREAM_REVIEW_SHA=""
  if [[ "$open_upstream" == 1 ]]; then
    git -C "$SEED" switch -q -C upstream-sync "$UPSTREAM_SHA"
    git -C "$SEED" commit -q --allow-empty -m "resolve upstream sync conflict"
    UPSTREAM_REVIEW_SHA="$(git -C "$SEED" rev-parse HEAD)"
    git -C "$SEED" push -q origin upstream-sync
  fi

  LINUX_REVIEW_SHA=""
  if [[ "$open_linux" == 1 ]]; then
    git -C "$SEED" switch -q -C linux-port-sync "$MASTER_SHA"
    git -C "$SEED" commit -q --allow-empty -m "resolve Linux sync conflict"
    LINUX_REVIEW_SHA="$(git -C "$SEED" rev-parse HEAD)"
    git -C "$SEED" push -q origin linux-port-sync
  fi

  git clone -q --branch linux-port "$ORIGIN" "$CHECKOUT"
}

run_workflow() {
  (
    cd "$CHECKOUT"
    export GH_TOKEN=test-token
    export GITHUB_REPOSITORY=example/agterm-linux
    export GH_STATE_DIR="$STATE"
    export PATH="$BIN:$PATH"
    export UPSTREAM_REPOSITORY="$UPSTREAM"
    export UPSTREAM_BRANCH=master
    export UPSTREAM_SYNC_BRANCH=upstream-sync
    export LINUX_SYNC_BRANCH=linux-port-sync
    for step in "$STEPS"/{1..5}.sh; do
      bash "$step"
    done
  )
}

prepare_fixture no-open-prs 0 0
run_workflow
assert_ref "$UPSTREAM_SHA" "$ORIGIN" refs/heads/upstream-sync
assert_ref "$MASTER_SHA" "$ORIGIN" refs/heads/linux-port-sync
assert_call $'create\tmaster\tupstream-sync'
assert_call $'create\tlinux-port\tlinux-port-sync'
echo "ok - no open PR creates both sync branches and PRs"

prepare_fixture open-upstream-pr 1 0
run_workflow
assert_ref "$UPSTREAM_REVIEW_SHA" "$ORIGIN" refs/heads/upstream-sync
assert_ref "$MASTER_SHA" "$ORIGIN" refs/heads/linux-port-sync
assert_call $'list\tlinux-port\tlinux-port-sync'
assert_call $'create\tlinux-port\tlinux-port-sync'
if grep -Fqx $'create\tmaster\tupstream-sync' "$CALLS"; then
  fail "created a duplicate upstream PR"
fi
echo "ok - open upstream PR is preserved and Linux sync continues"

prepare_fixture open-review-prs 1 1
run_workflow
assert_ref "$UPSTREAM_REVIEW_SHA" "$ORIGIN" refs/heads/upstream-sync
assert_ref "$LINUX_REVIEW_SHA" "$ORIGIN" refs/heads/linux-port-sync
assert_call $'list\tlinux-port\tlinux-port-sync'
if grep -q '^create' "$CALLS"; then
  fail "created a duplicate PR while review PRs were open"
fi
echo "ok - in-progress conflict-resolution commits are not overwritten"
