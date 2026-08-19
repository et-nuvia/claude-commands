#!/usr/bin/env bash
# claude-audit.sh - Deterministic CLAUDE.md memory-file audit
#
# Scope (default = project/local):
#   ./claude-audit.sh                 # audit the PROJECT ./CLAUDE.md (default)
#   ./claude-audit.sh --local         # same as default (explicit)
#   ./claude-audit.sh --global        # audit ~/.claude/CLAUDE.md
#   ./claude-audit.sh --both          # audit BOTH + cross-analysis (dupes/conflicts)
#   ./claude-audit.sh --file PATH     # audit a specific file
#   ./claude-audit.sh --output FILE   # override JSON output path
#
# Standard: ~/projects/wiki/patterns/claude-md-authoring.md
# JSON to stdout (+ /tmp file); human messages to stderr.
# Self-contained: no PROJECT.yaml or shared libs required.

set -euo pipefail

LINES_TARGET=200
LINES_DEGRADE=250
TOKENS_TARGET=2500
CHARS_PER_TOKEN=4

SCOPE="local"            # default = project file
CUSTOM_FILE=""
OUTPUT_FILE="/tmp/claude-audit-result.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)   SCOPE="local"; shift ;;
    --global)  SCOPE="global"; shift ;;
    --both)    SCOPE="both"; shift ;;
    --file)    SCOPE="custom"; CUSTOM_FILE="$2"; shift 2 ;;
    --output)  OUTPUT_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: claude-audit.sh [--local|--global|--both|--file PATH] [--output FILE]" >&2
      exit 2 ;;
  esac
done

GLOBAL_TARGET="${HOME}/.claude/CLAUDE.md"
if [[ -f "${PWD}/CLAUDE.md" ]]; then
  LOCAL_TARGET="${PWD}/CLAUDE.md"
elif [[ -f "${PWD}/.claude/CLAUDE.md" ]]; then
  LOCAL_TARGET="${PWD}/.claude/CLAUDE.md"
else
  LOCAL_TARGET="${PWD}/CLAUDE.md"   # may not exist
fi

clamp() { local v="$1"; (( v < 0 )) && v=0; (( v > 100 )) && v=100; echo "$v"; }

# ---------------------------------------------------------------------------
# audit_one <file> <role>  -> prints a JSON object for that file (or null)
# Sets globals: AO_LINES AO_TOKENS (for combined totals)
# ---------------------------------------------------------------------------
AO_LINES=0; AO_TOKENS=0
audit_one() {
  local file="$1" role="$2"
  if [[ ! -f "$file" ]]; then
    AO_LINES=0; AO_TOKENS=0
    jq -n --arg role "$role" --arg target "$file" \
      '{role:$role, target:$target, status:"missing", findings:["CLAUDE.md not found at this path"]}'
    return
  fi

  local nocomment lines chars tokens
  nocomment="$(perl -0777 -pe 's/<!--.*?-->//gs' "$file" 2>/dev/null || cat "$file")"
  lines=$(wc -l < "$file" | tr -d ' ')
  chars=$(printf '%s' "$nocomment" | wc -c | tr -d ' ')
  tokens=$(( chars / CHARS_PER_TOKEN ))
  AO_LINES=$lines; AO_TOKENS=$tokens

  local h2 h3 bullets fences code_blocks tables steps
  h2=$(grep -cE '^## '  "$file" || true)
  h3=$(grep -cE '^### ' "$file" || true)
  bullets=$(grep -cE '^[[:space:]]*[-*] ' "$file" || true)
  fences=$(grep -cE '^```' "$file" || true); code_blocks=$(( fences / 2 ))
  tables=$(grep -cE '^\|' "$file" || true)
  steps=$(grep -cE '^[[:space:]]*[0-9]+\. ' "$file" || true)

  local imports rules_dir rules_present rules_files catalog_lines
  imports=$(grep -cE '^@|[[:space:]]@[~./]' "$file" || true)
  rules_dir="$(dirname "$file")/.claude/rules"
  [[ "$role" == "global" ]] && rules_dir="${HOME}/.claude/rules"
  rules_present=false; rules_files=0
  if [[ -d "$rules_dir" ]]; then
    rules_present=true
    rules_files=$(find "$rules_dir" -maxdepth 2 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  fi
  catalog_lines=$(grep -ciE '^- .*(`/[a-z]|\.sh\b|\.py\b)' "$file" || true)

  local html_comments commented_code secret_hits
  html_comments=$(grep -cE '<!--' "$file" || true)
  commented_code=$(grep -cE '^[[:space:]]*//|^[[:space:]]*#.*TODO' "$file" || true)
  secret_hits=$(grep -ciE '(api[_-]?key|secret|password|token|glrt-|AKIA|-----BEGIN)[^a-z]*[=:]' "$file" || true)

  # ---- scores ----
  local s_size=100 over tover
  if (( lines > LINES_TARGET )); then over=$(( lines - LINES_TARGET )); s_size=$(( 100 - over / 3 )); fi
  if (( tokens > TOKENS_TARGET )); then tover=$(( (tokens - TOKENS_TARGET) / 40 )); s_size=$(( s_size - tover )); fi
  s_size=$(clamp "$s_size")

  local s_struct=100 avg
  (( h2 == 0 )) && s_struct=$(( s_struct - 30 ))
  if (( h2 > 0 )); then avg=$(( lines / h2 )); (( avg > 25 )) && s_struct=$(( s_struct - (avg - 25) )); fi
  s_struct=$(clamp "$s_struct")

  local s_eff=100
  (( imports > 0 )) && s_eff=$(( s_eff - imports * 8 ))
  if (( lines > LINES_TARGET )); then
    [[ "$rules_present" == false ]] && s_eff=$(( s_eff - 25 ))
    (( $(grep -ciE 'skill' "$file" || true) == 0 )) && s_eff=$(( s_eff - 10 ))
  fi
  s_eff=$(clamp "$s_eff")

  local s_fit=100
  (( code_blocks > 4 ))    && s_fit=$(( s_fit - (code_blocks - 4) * 5 ))
  (( steps > 8 ))          && s_fit=$(( s_fit - (steps - 8) * 2 ))
  (( catalog_lines > 10 )) && s_fit=$(( s_fit - (catalog_lines - 10) ))
  s_fit=$(clamp "$s_fit")

  local s_hyg=100
  (( secret_hits > 0 ))    && s_hyg=$(( s_hyg - secret_hits * 30 ))
  (( commented_code > 0 )) && s_hyg=$(( s_hyg - commented_code * 3 ))
  s_hyg=$(clamp "$s_hyg")

  local overall rating
  overall=$(( (s_size*35 + s_struct*20 + s_eff*20 + s_fit*15 + s_hyg*10) / 100 ))
  if   (( overall >= 90 )); then rating="EXCELLENT"
  elif (( overall >= 70 )); then rating="GOOD"
  elif (( overall >= 50 )); then rating="FAIR"
  else                           rating="NEEDS WORK"; fi

  # ---- findings ----
  local f=()
  (( lines > LINES_DEGRADE )) && f+=("CRITICAL: ${lines} lines exceeds the ${LINES_DEGRADE}-line degradation threshold — move content to skills / path-scoped rules.")
  (( lines > LINES_TARGET && lines <= LINES_DEGRADE )) && f+=("WARN: ${lines} lines is over the ~${LINES_TARGET}-line target.")
  (( tokens > TOKENS_TARGET )) && f+=("WARN: ~${tokens} est. tokens exceeds the ~${TOKENS_TARGET}-token budget (paid every session AND in every non-Explore/Plan subagent).")
  (( imports > 0 )) && f+=("INFO: ${imports} @import(s) — load eagerly, NO token savings; readability only.")
  if (( lines > LINES_TARGET )) && [[ "$rules_present" == false ]]; then
    f+=("WARN: Large file but no ${rules_dir} — domain rules should be path-scoped (lazy-loaded).")
  fi
  (( code_blocks > 4 ))    && f+=("INFO: ${code_blocks} code blocks — multi-step procedures usually belong in Skills.")
  (( catalog_lines > 10 )) && f+=("INFO: ~${catalog_lines} catalog/list lines — reference catalogs load every turn; link a doc instead.")
  (( secret_hits > 0 ))    && f+=("CRITICAL: ${secret_hits} possible secret pattern(s) — review and remove; CLAUDE.md is shared context.")
  (( commented_code > 0 )) && f+=("INFO: ${commented_code} commented-out/TODO line(s) — prefer HTML comments (0 tokens).")
  [[ "$rules_present" == true ]] && f+=("GOOD: ${rules_files} path-scoped rule file(s) present (lazy-loaded).")
  (( ${#f[@]} == 0 )) && f+=("GOOD: No issues detected.")

  local findings_json
  findings_json=$(printf '%s\n' "${f[@]}" | jq -R . | jq -s .)

  jq -n \
    --arg role "$role" --arg target "$file" \
    --argjson lines "$lines" --argjson tokens "$tokens" --argjson chars "$chars" \
    --argjson h2 "$h2" --argjson h3 "$h3" --argjson bullets "$bullets" \
    --argjson code_blocks "$code_blocks" --argjson tables "$tables" --argjson steps "$steps" \
    --argjson imports "$imports" --arg rules_present "$rules_present" \
    --argjson rules_files "$rules_files" --argjson catalog_lines "$catalog_lines" \
    --argjson html_comments "$html_comments" --argjson secret_hits "$secret_hits" \
    --argjson s_size "$s_size" --argjson s_struct "$s_struct" --argjson s_eff "$s_eff" \
    --argjson s_fit "$s_fit" --argjson s_hyg "$s_hyg" \
    --argjson overall "$overall" --arg rating "$rating" \
    --argjson findings "$findings_json" \
    '{
      role:$role, target:$target, status:"ok",
      metrics:{ total_lines:$lines, est_tokens:$tokens, effective_chars:$chars,
        structure:{h2:$h2,h3:$h3,bullets:$bullets,code_blocks:$code_blocks,tables:$tables,numbered_steps:$steps},
        efficiency:{imports:$imports, rules_dir_present:$rules_present, rules_files:$rules_files, catalog_lines:$catalog_lines},
        hygiene:{html_comments:$html_comments, secret_pattern_hits:$secret_hits} },
      scores:{ size_budget:$s_size, structure_terseness:$s_struct, token_efficiency:$s_eff, content_fit:$s_fit, hygiene_safety:$s_hyg },
      overall_score:$overall, rating:$rating, findings:$findings
    }'
}

# ---------------------------------------------------------------------------
# cross_analysis <global_file> <local_file> -> JSON (duplicates + conflict candidates)
# ---------------------------------------------------------------------------
cross_analysis() {
  local gf="$1" lf="$2"
  # normalize: trim, drop blanks/headings/short lines, unique-sort
  local norm='s/^[[:space:]]+//; s/[[:space:]]+$//'
  local gtmp ltmp dup
  gtmp=$(mktemp); ltmp=$(mktemp)
  sed -E "$norm" "$gf" | grep -vE '^(#|$|\||---|```)' | awk 'length($0) >= 15' | sort -u > "$gtmp"
  sed -E "$norm" "$lf" | grep -vE '^(#|$|\||---|```)' | awk 'length($0) >= 15' | sort -u > "$ltmp"
  dup=$(comm -12 "$gtmp" "$ltmp")
  local dup_count dup_json
  dup_count=$([[ -z "$dup" ]] && echo 0 || printf '%s\n' "$dup" | wc -l | tr -d ' ')
  dup_json=$([[ -z "$dup" ]] && echo '[]' || printf '%s\n' "$dup" | head -25 | jq -R . | jq -s .)

  # directive lines (potential contradictions) from each file, for LLM comparison
  local dir_re='NEVER|ALWAYS|MUST|DO NOT|DON.?T|REQUIRED|FORBIDDEN|ONLY'
  local gdir ldir
  gdir=$(grep -hE "$dir_re" "$gf" | sed -E "$norm" | head -40 | jq -R . | jq -s .)
  ldir=$(grep -hE "$dir_re" "$lf" | sed -E "$norm" | head -40 | jq -R . | jq -s .)

  rm -f "$gtmp" "$ltmp"
  jq -n --argjson dup_count "$dup_count" --argjson duplicates "$dup_json" \
        --argjson global_directives "$gdir" --argjson local_directives "$ldir" \
    '{
      duplicate_line_count:$dup_count,
      duplicate_lines:$duplicates,
      directive_lines:{ global:$global_directives, local:$local_directives },
      note:"duplicate_lines are exact normalized matches present in BOTH files (redundant always-on cost). directive_lines are ALWAYS/NEVER/MUST-style rules from each file — compare across files for contradictions and for rules that are less applicable in one scope."
    }'
}

# ---------------------------------------------------------------------------
# Build result by scope
# ---------------------------------------------------------------------------
# lines/tokens are read back from the emitted JSON (audit_one runs in a subshell,
# so its AO_* globals don't propagate to the parent).
lines_of()  { echo "$1" | jq '.metrics.total_lines // 0'; }
tokens_of() { echo "$1" | jq '.metrics.est_tokens // 0'; }

case "$SCOPE" in
  local)
    obj=$(audit_one "$LOCAL_TARGET" "local")
    FILES_JSON="[$obj]"; COMBINED_LINES=$(lines_of "$obj"); COMBINED_TOKENS=$(tokens_of "$obj"); CROSS_JSON="null" ;;
  global)
    obj=$(audit_one "$GLOBAL_TARGET" "global")
    FILES_JSON="[$obj]"; COMBINED_LINES=$(lines_of "$obj"); COMBINED_TOKENS=$(tokens_of "$obj"); CROSS_JSON="null" ;;
  custom)
    obj=$(audit_one "$CUSTOM_FILE" "custom")
    FILES_JSON="[$obj]"; COMBINED_LINES=$(lines_of "$obj"); COMBINED_TOKENS=$(tokens_of "$obj"); CROSS_JSON="null" ;;
  both)
    gobj=$(audit_one "$GLOBAL_TARGET" "global")
    lobj=$(audit_one "$LOCAL_TARGET" "local")
    FILES_JSON="[$gobj,$lobj]"
    COMBINED_LINES=$(( $(lines_of "$gobj") + $(lines_of "$lobj") ))
    COMBINED_TOKENS=$(( $(tokens_of "$gobj") + $(tokens_of "$lobj") ))
    if [[ -f "$GLOBAL_TARGET" && -f "$LOCAL_TARGET" ]]; then
      CROSS_JSON=$(cross_analysis "$GLOBAL_TARGET" "$LOCAL_TARGET")
    else
      CROSS_JSON='{"note":"cross-analysis skipped — one or both files missing"}'
    fi ;;
esac

# next_action
NEXT="generate_report_with_fixes"
if [[ "$SCOPE" == "both" ]]; then
  NEXT="compare_and_report"
else
  worst=$(echo "$FILES_JSON" | jq '[.[]|.overall_score // 0]|min')
  secrets=$(echo "$FILES_JSON" | jq '[.[]|.metrics.hygiene.secret_pattern_hits // 0]|add')
  if   (( secrets > 0 ));  then NEXT="remediate_secrets"
  elif (( worst >= 90 )); then NEXT="display_summary"
  elif (( worst >= 70 )); then NEXT="generate_report_with_recommendations"
  else                         NEXT="generate_report_with_fixes"; fi
fi

jq -n \
  --arg scope "$SCOPE" \
  --argjson files "$FILES_JSON" \
  --argjson combined_lines "$COMBINED_LINES" \
  --argjson combined_tokens "$COMBINED_TOKENS" \
  --argjson cross "$CROSS_JSON" \
  --arg next_action "$NEXT" \
  '{
    status:"ok",
    scope:$scope,
    files:$files,
    combined_always_on:{ total_lines:$combined_lines, est_tokens:$combined_tokens,
      note:"For project sessions, global + project CLAUDE.md both load and stack in context (and re-load in every non-Explore/Plan subagent)." },
    cross_analysis:$cross,
    next_action:$next_action
  }' | tee "$OUTPUT_FILE"
