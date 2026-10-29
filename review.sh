#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="origin/renovate/kimdre-doco-cd-0.x"

CLAUDE_MODEL="claude-fable-5"
CLAUDE_EFFORT="xhigh"
CODEX_MODEL="gpt-5.6-sol"
CODEX_EFFORT="xhigh"

# --- Terminal formatting ---

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info() { printf '%b▸%b %s\n' "$CYAN" "$RESET" "$*"; }
success() { printf '%b✔%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b▲%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fatal() { printf '%b✘%b %b%s%b\n' "$RED" "$RESET" "$BOLD" "$*" "$RESET" >&2; }
header() { printf '\n%b%s%b\n' "$BOLD" "$*" "$RESET"; }
divider() {
  printf '%b' "$DIM"
  printf '%.0s─' {1..60}
  printf '%b\n' "$RESET"
}
field() { printf '  %b%-14s%b %s\n' "$DIM" "$1" "$RESET" "$2"; }
show_tail() {
  # usage: show_tail <label> <file>
  printf '%b%s (last 40 lines):%b\n' "$DIM" "$1" "$RESET"
  tail -n 40 "$2" 2>/dev/null || true
}

fmt_duration() {
  # usage: fmt_duration <milliseconds>
  local secs=$(($1 / 1000))
  printf '%d:%02d' $((secs / 60)) $((secs % 60))
}

# Validates a `claude -p --output-format json` result file and writes the
# report text to the output file. Prints a reason on stderr when invalid.
# usage: extract_claude_result <json_file> <out_file>
extract_claude_result() {
  local json_file="$1" out_file="$2" subtype is_error
  if ! jq -e 'type == "object"' "$json_file" >/dev/null 2>&1; then
    echo "output is not a JSON object" >&2
    return 1
  fi
  subtype="$(jq -r '.subtype // "missing"' "$json_file")"
  is_error="$(jq -r '.is_error // false' "$json_file")"
  if [[ "$subtype" != "success" || "$is_error" != "false" ]]; then
    echo "result subtype '$subtype' (is_error=$is_error)" >&2
    return 1
  fi
  jq -r '.result // empty' "$json_file" >"$out_file"
  if [[ ! -s "$out_file" ]]; then
    echo "result contains no report text" >&2
    return 1
  fi
}

# usage: claude_stats <json_file>  -> "duration · cost"
claude_stats() {
  jq -r '"\(.duration_ms // 0)\t\(.total_cost_usd // 0)"' "$1" |
    while IFS=$'\t' read -r ms cost; do
      LC_ALL=C printf '%s · $%.2f' "$(fmt_duration "$ms")" "$cost"
    done
}

for tool in claude codex jq git; do
  command -v "$tool" >/dev/null 2>&1 || {
    fatal "Required tool not found: $tool"
    exit 1
  }
done

CLAUDE_CODE_VERSION="$(claude --version 2>/dev/null || echo unknown)"
CODEX_VERSION="$(codex --version 2>/dev/null || echo unknown)"

# --- Setup temp dir and worktree ---

TMPDIR_BASE="$(mktemp -d)"
WORKTREE="$TMPDIR_BASE/review-worktree"

cleanup() {
  printf '\033[?25h'
  divider
  info "Cleaning up worktree and temp files..."
  git -C "$SCRIPT_DIR" worktree remove --force "$WORKTREE" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

header "Stage 1: Setup"
divider

info "Fetching origin..."
git -C "$SCRIPT_DIR" fetch origin --quiet

printf '%b▸%b Creating worktree for %b%s%b...\n' "$CYAN" "$RESET" "$BOLD" "$BRANCH" "$RESET"
git -C "$SCRIPT_DIR" worktree add --detach "$WORKTREE" "$BRANCH" 2>/dev/null

DOCO_VERSION_CURRENT="$(cat "$SCRIPT_DIR/.doco-cd-version" 2>/dev/null || echo unknown)"
DOCO_VERSION_TARGET="$(cat "$WORKTREE/.doco-cd-version" 2>/dev/null || echo unknown)"

success "Worktree ready"
field "Upgrade path:" "$DOCO_VERSION_CURRENT → $DOCO_VERSION_TARGET"
field "Claude Code:" "$CLAUDE_CODE_VERSION │ $CLAUDE_MODEL │ effort: $CLAUDE_EFFORT"
field "Codex:" "$CODEX_VERSION │ $CODEX_MODEL │ reasoning: $CODEX_EFFORT"

# --- Build review prompt ---

REVIEW_INSTRUCTIONS="$(cat "$SCRIPT_DIR/AI_REVIEW_PROMPT.md")"

PROMPT="$REVIEW_INSTRUCTIONS

---

IMPORTANT: You are running inside a read-only sandbox. The filesystem is mounted read-only and you cannot modify any files. Do NOT attempt to write, edit, or create files. You may encounter minor write failures from tools trying to update cache files or similar — ignore these, they do not affect your investigation. Focus exclusively on reading files and running read-only commands (git diff, git log, cat, grep, etc.).

You are now executing this review. The repository is located at: $WORKTREE
The branch under review is checked out. Compare against origin/main to identify changes.

This update covers the upgrade from $DOCO_VERSION_CURRENT to $DOCO_VERSION_TARGET. This may span multiple upstream releases, so the diff can be large. Review all changes regardless of how many upstream versions they cover.

Produce the full Security Report as described above."

# --- Stage 2: Parallel reviews ---

header "Stage 2: Parallel Reviews"
divider

CLAUDE_JSON="$TMPDIR_BASE/claude-review.json"
CLAUDE_OUT="$TMPDIR_BASE/claude-review.md"
CLAUDE_ERR="$TMPDIR_BASE/claude-review.err"
CODEX_OUT="$TMPDIR_BASE/codex-review.md"
CODEX_LOG="$TMPDIR_BASE/codex-review.log"

PROMPT_FILE="$TMPDIR_BASE/review-prompt.txt"
printf '%s' "$PROMPT" >"$PROMPT_FILE"

# Claude Code in print mode denies file writes and mutating shell commands
# while allowing read-only ones, which is the behaviour the prompt relies on.
# The JSON output carries the report plus a success flag, duration and cost.
info "Starting Claude Code review..."
(
  cd "$WORKTREE"
  claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
    --permission-mode manual --output-format json --no-session-persistence
) <"$PROMPT_FILE" >"$CLAUDE_JSON" 2>"$CLAUDE_ERR" &
CLAUDE_PID=$!

# Codex writes the final message to a file; stdout and stderr carry progress.
info "Starting Codex review..."
(
  cd "$WORKTREE"
  codex exec -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
    --sandbox read-only --ephemeral --color never \
    -C "$WORKTREE" --output-last-message "$CODEX_OUT" -
) <"$PROMPT_FILE" >"$CODEX_LOG" 2>&1 &
CODEX_PID=$!

SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
printf '\033[?25l'
CLAUDE_EXIT=""
CODEX_EXIT=""
CLAUDE_ICON="⏳"
CODEX_ICON="⏳"
START_TIME=$SECONDS
FRAME=0

while [[ -z "$CLAUDE_EXIT" || -z "$CODEX_EXIT" ]]; do
  ELAPSED=$((SECONDS - START_TIME))
  TIMESTAMP=$(printf '%d:%02d' $((ELAPSED / 60)) $((ELAPSED % 60)))
  SPIN="${SPINNER_FRAMES[$((FRAME % ${#SPINNER_FRAMES[@]}))]}"
  FRAME=$((FRAME + 1))

  if [[ -z "$CLAUDE_EXIT" ]] && ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
    wait "$CLAUDE_PID" 2>/dev/null && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?
    [[ $CLAUDE_EXIT -eq 0 ]] && CLAUDE_ICON="✅" || CLAUDE_ICON="❌"
  fi

  if [[ -z "$CODEX_EXIT" ]] && ! kill -0 "$CODEX_PID" 2>/dev/null; then
    wait "$CODEX_PID" 2>/dev/null && CODEX_EXIT=0 || CODEX_EXIT=$?
    [[ $CODEX_EXIT -eq 0 ]] && CODEX_ICON="✅" || CODEX_ICON="❌"
  fi

  printf '\r\033[2K%b%s%b %b%s%b │ Claude Code %b%s %s%b %s │ Codex %b%s %s%b %s' \
    "$CYAN" "$SPIN" "$RESET" "$DIM" "$TIMESTAMP" "$RESET" \
    "$DIM" "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$RESET" "$CLAUDE_ICON" \
    "$DIM" "$CODEX_MODEL" "$CODEX_EFFORT" "$RESET" "$CODEX_ICON"

  if [[ -z "$CLAUDE_EXIT" || -z "$CODEX_EXIT" ]]; then
    sleep 1
  fi
done
printf '\033[?25h\n'

# --- Validate reviewer output ---

FAILED=0

CLAUDE_REASON=""
if [[ $CLAUDE_EXIT -ne 0 ]]; then
  CLAUDE_REASON="exit code $CLAUDE_EXIT"
elif ! CLAUDE_REASON="$(extract_claude_result "$CLAUDE_JSON" "$CLAUDE_OUT" 2>&1)"; then
  CLAUDE_EXIT=1
fi

if [[ $CLAUDE_EXIT -ne 0 ]]; then
  FAILED=1
  printf '\n%b── Claude Code failed: %s ──%b\n' "$DIM" "$CLAUDE_REASON" "$RESET"
  show_tail "stdout" "$CLAUDE_JSON"
  printf '\n'
  show_tail "stderr" "$CLAUDE_ERR"
  divider
else
  success "Claude Code review finished ($(claude_stats "$CLAUDE_JSON"))"
fi

CODEX_REASON=""
if [[ $CODEX_EXIT -ne 0 ]]; then
  CODEX_REASON="exit code $CODEX_EXIT"
elif [[ ! -s "$CODEX_OUT" ]]; then
  CODEX_EXIT=1
  CODEX_REASON="no final message was written"
fi

if [[ $CODEX_EXIT -ne 0 ]]; then
  FAILED=1
  printf '\n%b── Codex failed: %s ──%b\n' "$DIM" "$CODEX_REASON" "$RESET"
  show_tail "output" "$CODEX_LOG"
  divider
else
  success "Codex review finished"
fi

if [[ $FAILED -ne 0 ]]; then
  fatal "Aborting — one or more reviewers failed."
  exit 1
fi

CLAUDE_REPORT="$(cat "$CLAUDE_OUT")"
CODEX_REPORT="$(cat "$CODEX_OUT")"

# --- Stage 3: Combine reports ---

header "Stage 3: Consolidation"
divider

info "Synthesizing final report..."

COMBINE_PROMPT="You are an editor consolidating two independent security reviews into one report. You do NOT perform your own code review. Your only sources of truth are the two reviewer reports below.

<role>
Your job is strictly editorial:
- Merge, deduplicate, and organize findings from both reports.
- Resolve conflicts: if reviewers disagree on severity or whether something is a real risk, note both positions and state which you find more convincing based on the reasoning provided.
- Correct obvious factual errors only when one report directly contradicts the other with better evidence.
- Do NOT re-analyze code, speculate about issues not mentioned by either reviewer, or add your own findings.
</role>

<review_metadata>
doco-cd upgrade: $DOCO_VERSION_CURRENT -> $DOCO_VERSION_TARGET
Review date: $(date -u +%Y-%m-%d)
Reviewer 1: Claude Code $CLAUDE_CODE_VERSION, model $CLAUDE_MODEL, effort $CLAUDE_EFFORT
Reviewer 2: Codex $CODEX_VERSION, model $CODEX_MODEL, reasoning effort $CODEX_EFFORT
</review_metadata>

<reviewer_report reviewer=\"Claude Code ($CLAUDE_MODEL)\">
$CLAUDE_REPORT
</reviewer_report>

<reviewer_report reviewer=\"Codex ($CODEX_MODEL)\">
$CODEX_REPORT
</reviewer_report>

<output_format>
Produce a single markdown document. Output only the markdown, no preamble or commentary. Use this exact structure:

# Security Review: doco-cd $DOCO_VERSION_CURRENT -> $DOCO_VERSION_TARGET

## Review Metadata

| Property | Value |
|----------|-------|
| Upgrade path | $DOCO_VERSION_CURRENT -> $DOCO_VERSION_TARGET |
| Review date | YYYY-MM-DD |
| Reviewer 1 | Claude Code VERSION, model MODEL, effort EFFORT |
| Reviewer 2 | Codex VERSION, model MODEL, reasoning effort EFFORT |

## Summary of Changes

2-4 paragraphs describing what this update introduces, synthesized from both reports.

## Dependency Review

Note any newly introduced dependencies and whether they pose a risk. If no new dependencies were added, state that explicitly.

## Security Findings

One ### subheading per finding. For each finding include:
- Description of the issue
- Which reviewer(s) flagged it (one, both, or conflicting assessments)
- Severity: Critical / High / Medium / Low / Informational
- Assessment: whether this is a real risk, drawing on the reviewers' reasoning

If neither reviewer found issues, state that explicitly with a single paragraph instead of subheadings.

## Reviewer Agreement

One short paragraph noting where the two reviewers agreed and where they differed.

## Verdict

A single bolded verdict: **SAFE**, **SAFE WITH NOTES**, or **UNSAFE**, followed by a 1-3 sentence justification based solely on the findings above.
</output_format>"

COMBINE_JSON="$TMPDIR_BASE/combine-review.json"
COMBINE_ERR="$TMPDIR_BASE/combine-review.err"
COMBINE_PROMPT_FILE="$TMPDIR_BASE/combine-prompt.txt"
FINAL_OUT="$TMPDIR_BASE/final-review.md"
printf '%s' "$COMBINE_PROMPT" >"$COMBINE_PROMPT_FILE"

# The editor step is purely text-to-text, so all tools are disabled.
COMBINE_EXIT=0
(
  cd "$WORKTREE"
  claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
    --tools "" --output-format json --no-session-persistence
) <"$COMBINE_PROMPT_FILE" >"$COMBINE_JSON" 2>"$COMBINE_ERR" ||
  COMBINE_EXIT=$?

COMBINE_REASON=""
if [[ $COMBINE_EXIT -ne 0 ]]; then
  COMBINE_REASON="exit code $COMBINE_EXIT"
elif ! COMBINE_REASON="$(extract_claude_result "$COMBINE_JSON" "$FINAL_OUT" 2>&1)"; then
  COMBINE_EXIT=1
fi

if [[ $COMBINE_EXIT -ne 0 ]]; then
  fatal "Consolidation failed: $COMBINE_REASON"
  divider
  show_tail "stdout" "$COMBINE_JSON"
  printf '\n'
  show_tail "stderr" "$COMBINE_ERR"
  divider
  exit 1
fi

success "Report consolidated ($(claude_stats "$COMBINE_JSON"))"

# --- Stage 4: Save and display ---

header "Stage 4: Report"
divider

REVIEWS_DIR="$SCRIPT_DIR/reviews"
mkdir -p "$REVIEWS_DIR"
REPORT_NAME="${DOCO_VERSION_CURRENT}_to_${DOCO_VERSION_TARGET}.md"
cp "$FINAL_OUT" "$REVIEWS_DIR/$REPORT_NAME"

printf '%b✔%b Saved to %b%s%b\n\n' "$GREEN" "$RESET" "$BOLD" "reviews/$REPORT_NAME" "$RESET"

glow "$REVIEWS_DIR/$REPORT_NAME" || cat "$REVIEWS_DIR/$REPORT_NAME"
