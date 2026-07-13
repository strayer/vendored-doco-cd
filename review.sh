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

info() { printf "${CYAN}▸${RESET} %s\n" "$*"; }
success() { printf "${GREEN}✔${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}▲${RESET} %s\n" "$*" >&2; }
fatal() { printf "${RED}✘${RESET} ${BOLD}%s${RESET}\n" "$*" >&2; }
header() { printf "\n${BOLD}%s${RESET}\n" "$*"; }
divider() {
  printf "${DIM}%.0s─${RESET}" {1..60}
  printf "\n"
}

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

printf "${CYAN}▸${RESET} Creating worktree for ${BOLD}%s${RESET}...\n" "$BRANCH"
git -C "$SCRIPT_DIR" worktree add --detach "$WORKTREE" "$BRANCH" 2>/dev/null

DOCO_VERSION_CURRENT="$(cat "$SCRIPT_DIR/.doco-cd-version" 2>/dev/null || echo unknown)"
DOCO_VERSION_TARGET="$(cat "$WORKTREE/.doco-cd-version" 2>/dev/null || echo unknown)"

success "Worktree ready"
printf "  ${DIM}Upgrade path:${RESET}  %s → %s\n" "$DOCO_VERSION_CURRENT" "$DOCO_VERSION_TARGET"
printf "  ${DIM}Claude Code:${RESET}   %s │ %s │ effort: %s\n" "$CLAUDE_CODE_VERSION" "$CLAUDE_MODEL" "$CLAUDE_EFFORT"
printf "  ${DIM}Codex:${RESET}         %s │ %s │ reasoning: %s\n" "$CODEX_VERSION" "$CODEX_MODEL" "$CODEX_EFFORT"

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

CLAUDE_OUT="$TMPDIR_BASE/claude-review.md"
CLAUDE_ERR="$TMPDIR_BASE/claude-review.err"
CODEX_OUT="$TMPDIR_BASE/codex-review.md"
CODEX_ERR="$TMPDIR_BASE/codex-review.err"

PROMPT_FILE="$TMPDIR_BASE/review-prompt.txt"
printf '%s' "$PROMPT" >"$PROMPT_FILE"

info "Starting Claude Code review..."
(
  cd "$WORKTREE"
  nono run --silent --profile claude-code --allow-cwd --read "$SCRIPT_DIR/.git" -- \
    claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --dangerously-skip-permissions
) <"$PROMPT_FILE" >"$CLAUDE_OUT" 2>"$CLAUDE_ERR" &
CLAUDE_PID=$!

info "Starting Codex review..."
(
  cd "$WORKTREE"
  nono run --silent --profile codex-cli --allow-cwd --read "$SCRIPT_DIR/.git" -- \
    codex exec -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=$CODEX_EFFORT" \
    --dangerously-bypass-approvals-and-sandbox \
    -C "$WORKTREE" -
) <"$PROMPT_FILE" >"$CODEX_OUT" 2>"$CODEX_ERR" &
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
  MINS=$((ELAPSED / 60))
  SECS=$((ELAPSED % 60))
  TIMESTAMP=$(printf "%d:%02d" "$MINS" "$SECS")
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

  printf "\r\033[2K${CYAN}%s${RESET} ${DIM}%s${RESET} │ Claude Code ${DIM}%s %s${RESET} %s │ Codex ${DIM}%s %s${RESET} %s" \
    "$SPIN" "$TIMESTAMP" \
    "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$CLAUDE_ICON" \
    "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_ICON"

  if [[ -z "$CLAUDE_EXIT" || -z "$CODEX_EXIT" ]]; then
    sleep 1
  fi
done
printf '\033[?25h\n'

FAILED=0

if [[ $CLAUDE_EXIT -ne 0 ]]; then
  FAILED=1
  printf "\n${DIM}── Claude Code output ──${RESET}\n"
  printf "${DIM}stdout:${RESET}\n"
  cat "$CLAUDE_OUT" 2>/dev/null || true
  printf "\n${DIM}stderr:${RESET}\n"
  cat "$CLAUDE_ERR" 2>/dev/null || true
  divider
fi

if [[ $CODEX_EXIT -ne 0 ]]; then
  FAILED=1
  printf "\n${DIM}── Codex output ──${RESET}\n"
  printf "${DIM}stdout:${RESET}\n"
  cat "$CODEX_OUT" 2>/dev/null || true
  printf "\n${DIM}stderr:${RESET}\n"
  cat "$CODEX_ERR" 2>/dev/null || true
  divider
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

FINAL_OUT="$TMPDIR_BASE/final-review.md"
COMBINE_ERR="$TMPDIR_BASE/combine-review.err"
COMBINE_PROMPT_FILE="$TMPDIR_BASE/combine-prompt.txt"
printf '%s' "$COMBINE_PROMPT" >"$COMBINE_PROMPT_FILE"

COMBINE_EXIT=0
(
  cd "$WORKTREE"
  nono run --silent --profile claude-code --allow-cwd -- \
    claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --dangerously-skip-permissions
) <"$COMBINE_PROMPT_FILE" >"$FINAL_OUT" 2>"$COMBINE_ERR" \
  || COMBINE_EXIT=$?

if [[ $COMBINE_EXIT -ne 0 ]]; then
  fatal "Consolidation failed (exit code $COMBINE_EXIT)"
  divider
  printf "${DIM}stdout:${RESET}\n"
  cat "$FINAL_OUT" 2>/dev/null || true
  printf "\n${DIM}stderr:${RESET}\n"
  cat "$COMBINE_ERR" 2>/dev/null || true
  divider
  exit 1
fi

success "Report consolidated"

# --- Stage 4: Save and display ---

header "Stage 4: Report"
divider

REVIEWS_DIR="$SCRIPT_DIR/reviews"
mkdir -p "$REVIEWS_DIR"
REPORT_NAME="${DOCO_VERSION_CURRENT}_to_${DOCO_VERSION_TARGET}.md"
cp "$FINAL_OUT" "$REVIEWS_DIR/$REPORT_NAME"

printf "${GREEN}✔${RESET} Saved to ${BOLD}%s${RESET}\n" "reviews/$REPORT_NAME"
printf "\n"

glow "$REVIEWS_DIR/$REPORT_NAME" || cat "$REVIEWS_DIR/$REPORT_NAME"
