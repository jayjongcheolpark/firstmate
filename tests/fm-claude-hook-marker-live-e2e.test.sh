#!/usr/bin/env bash
# Opt-in live guard for the POSITIVE half of the tracked .claude/settings.json
# marker guard (docs/turnend-guard.md "Harness integrations").
#
# Those entries run only when CLAUDECODE is present. That is a fact the VENDOR
# emits, so a stub can only confirm the assumption already written into the
# stub, and the failure mode is silent in the dangerous direction: a Claude hook
# process that stopped carrying the marker would make its guard exit 0 and
# disarm Claude's own session-start, pre-tool, and turn-end protection with no
# signal at all.
#
# tests/fm-turnend-guard.test.sh pins the guard LOGIC portably with real
# processes and no harness, including that each entry stays inert without the
# marker. Only this guard can see whether the marker actually arrives, and it
# checks EVERY hook kind those entries register for, because the marker reaching
# one kind says nothing about the others.
#
# It records each hook process's own environment from two independent sources -
# the shell view the guard expression itself evaluates in, and the kernel's copy
# via ps -Eww - inside a throwaway lab, so nothing here touches a real home, a
# real fleet, or the operator's Claude configuration.
#
# The measurement is confound-controlled: this guard usually runs from inside a
# Claude Code session, whose processes already carry CLAUDECODE. Every CLAUDE*
# variable is stripped before the probe session is launched and the launcher's
# own environment is recorded, so an observed marker must have been set by the
# probe's Claude Code rather than inherited.
#
# Run it after every Claude Code upgrade and before trusting refreshed evidence
# in docs/verification/supervision.md:
#
#   FM_CLAUDE_HOOK_MARKER_LIVE_E2E=1 tests/fm-claude-hook-marker-live-e2e.test.sh
#
# It costs one real model turn.
set -u

if [ "${FM_CLAUDE_HOOK_MARKER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_HOOK_MARKER_LIVE_E2E=1 to run the live Claude hook-marker regression"
  exit 0
fi

unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v claude >/dev/null 2>&1 || fail "claude not installed; this guard exists to measure the vendor marker and cannot pass without it"
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

VERSION="$(claude --version 2>/dev/null | head -1)"
[ -n "$VERSION" ] || fail "could not read a Claude Code version; refusing to record an unversioned result"
note "harness: claude $VERSION"

# Outside the repo on purpose, so a lab never shows up in a working tree a
# maintainer may be committing from while this guard runs.
LAB="${TMPDIR:-/tmp}/fm-claude-hook-marker-live-e2e.$$"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT INT TERM
mkdir -p "$LAB/proj" "$LAB/out" || fail "could not create the lab at $LAB"

# The recorder stands in for a guarded entry: it reads its OWN environment the
# same way the tracked guard expression does, plus the kernel's copy, and never
# blocks the session.
cat > "$LAB/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
root="$1"; kind="$2"
mkdir -p "$root"
payload="$(cat 2>/dev/null || :)"
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "?"' 2>/dev/null || echo '?')
env_val=$(env | sed -n 's/^CLAUDECODE=\(.*\)$/\1/p' | head -1)
ps_val=$(ps -Eww -p "$$" 2>/dev/null | grep -o 'CLAUDECODE=[^ ]*' | head -1 | cut -d= -f2)
printf '%s\t%s\tenv=%s\tps=%s\n' \
  "$kind" "$event" "${env_val:-ABSENT}" "${ps_val:-ABSENT}" >> "$root/seen.tsv"
exit 0
PROBE
chmod +x "$LAB/probe.sh"

# Records the exact environment claude is exec'd with, so the confound control
# is proven rather than assumed, then hands off to claude.
cat > "$LAB/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
env > "$1/launch-env.txt"
shift
exec claude "$@"
LAUNCH
chmod +x "$LAB/launch.sh"

# Registered through the project's own .claude/settings.json, the same shape the
# tracked firstmate entries use, and with the same matchers.
mkdir -p "$LAB/proj/.claude"
cat > "$LAB/proj/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$LAB/probe.sh $LAB/out SessionStart", "timeout": 60 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$LAB/probe.sh $LAB/out PreToolUse-Bash", "timeout": 60 } ] },
      { "matcher": ".*", "hooks": [ { "type": "command", "command": "$LAB/probe.sh $LAB/out PreToolUse-any", "timeout": 60 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$LAB/probe.sh $LAB/out Stop", "timeout": 60 } ] }
    ]
  }
}
EOF

unset_args=()
while IFS= read -r name; do unset_args+=(-u "$name"); done \
  < <(env | sed -n 's/^\(CLAUDE[A-Z_0-9]*\)=.*/\1/p' | sort -u)

( cd "$LAB/proj" && env "${unset_args[@]}" "$LAB/launch.sh" "$LAB/out" \
    -p 'Use the Bash tool to run exactly: echo marker-probe. Then reply with only the word done.' \
    --allowedTools Bash --permission-mode acceptEdits --output-format text \
    > "$LAB/out/session.log" 2>&1 )
status=$?
[ "$status" -eq 0 ] || {
  note "session log:"; sed 's/^/#   /' "$LAB/out/session.log" 2>/dev/null | head -20
  fail "the probe Claude session did not complete (exit $status); no marker conclusion can be drawn"
}

# Confound control: if the launcher still carried a marker, an observed marker
# downstream would prove nothing.
[ -s "$LAB/out/launch-env.txt" ] || fail "the launcher never recorded its environment; the confound control did not run"
if grep -q '^CLAUDECODE=' "$LAB/out/launch-env.txt"; then
  fail "CLAUDECODE survived into the probe launcher; this run cannot distinguish an inherited marker from one Claude set"
fi

[ -s "$LAB/out/seen.tsv" ] || fail "no Claude hook fired at all under claude $VERSION; this guard refuses to pass having checked nothing"

# Every kind the tracked entries register must have fired AND carried the marker
# in both views. A kind that never fired is unmeasured, not passing.
checked=0
for kind in SessionStart PreToolUse-Bash PreToolUse-any Stop; do
  rows=$(awk -F'\t' -v k="$kind" '$1 == k' "$LAB/out/seen.tsv")
  [ -n "$rows" ] || fail "hook kind $kind never fired under claude $VERSION; it is UNMEASURED, so the positive CLAUDECODE guard on the tracked entries is not established for it"
  while IFS= read -r row; do
    case "$row" in
      *"env=ABSENT"*) fail "hook kind $kind ran WITHOUT CLAUDECODE under claude $VERSION; the tracked entries' positive guard would exit 0 and silently disarm Claude's own protection ($row)" ;;
      *"ps=ABSENT"*)  fail "hook kind $kind carried CLAUDECODE in the shell view but not in the kernel's copy under claude $VERSION; the two sources disagree ($row)" ;;
    esac
    checked=$((checked + 1))
  done <<< "$rows"
done

[ "$checked" -ge 4 ] || fail "expected at least 4 recorded hook invocations, saw $checked"
note "recorded invocations:"
sed 's/^/#   /' "$LAB/out/seen.tsv"
pass "claude $VERSION: CLAUDECODE reached all $checked recorded hook invocations across SessionStart, both PreToolUse matchers, and Stop, in both the shell and kernel views"
