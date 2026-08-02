#!/usr/bin/env bash
# verify-sweep.sh — training-aware, sequential verification of ten-proofs.
#
# For each target, in order:
#   GATE     — before starting, consult training-sentinel. While it says BACKOFF,
#              sleep and retry up to MAX_WAIT; if still blocked, DEFER the proof.
#   BUILD    — nice -n 15 lake build (training always wins CPU), ONE at a time.
#   WATCHDOG — while building, sample free memory; if below CRIT_MEM for 3 checks,
#              KILL the build (cleanup) and DEFER the proof, so training is never
#              OOM'd by a verify that started before training ramped up.
# Deferred proofs are retried on a second pass. Report -> BUILD_STATUS.md.
set -u
R="$HOME/ghq/github.com/openai/ten-proofs"
SENTINEL="$HOME/ghq/github.com/aygp-dr/jwalsh/build-a-large-language-model/ops/training-sentinel.sh"
LEAN="$HOME/.elan/bin/lake"
LOG=/tmp/tenproofs-sweep.log
REPORT="$R/BUILD_STATUS.md"
MAX_WAIT=${MAX_WAIT:-1800}      # give up gating after 30 min -> defer
GATE_SLEEP=${GATE_SLEEP:-30}
CRIT_MEM=${CRIT_MEM:-10}        # free% floor; watchdog kills build below this
DISK_MIN_KB=4194304            # abort sweep under 4G free

cd "$R" || exit 1
: > "$LOG"

# cheapest-looking first; heavy three (SpherePacking/MetricCodes/GapCVP) last
TARGETS="MulticolorTriangleRamsey ComparatorChallenges Permanent NonSoficGroup EhrhartVolumeInequality ConnesRigidity QuantumParallelRepetition CompactnessAndDegeneracy SpherePacking MetricCodes GapCVP"

freemem() { memory_pressure 2>/dev/null | awk -F: '/free percentage/{gsub(/[^0-9]/,"",$2);print $2}'; }
sorries() {
  local t=$1
  if [ -f "$t.lean" ]; then grep -cE '(^|[^A-Za-z])(sorry|admit)([^A-Za-z]|$)' "$t.lean" 2>/dev/null
  elif [ -d "$t" ]; then grep -rhcE '(^|[^A-Za-z])(sorry|admit)([^A-Za-z]|$)' "$t" 2>/dev/null | awk '{s+=$1}END{print s+0}'
  else echo "?"; fi
}

# build one target under the memory watchdog. echoes result token.
build_watched() {
  local t=$1
  nice -n 15 "$LEAN" build "$t" >>"$LOG" 2>&1 &
  local bpid=$! crit=0
  while kill -0 "$bpid" 2>/dev/null; do
    local f; f=$(freemem)
    if [ -n "$f" ] && [ "$f" -lt "$CRIT_MEM" ]; then crit=$((crit+1)); else crit=0; fi
    if [ "$crit" -ge 3 ]; then
      echo "$(date '+%H:%M:%S') WATCHDOG mem<${CRIT_MEM}% x3 -> kill $t" >>"$LOG"
      kill "$bpid" 2>/dev/null; sleep 3; kill -9 "$bpid" 2>/dev/null; pkill -P "$bpid" 2>/dev/null
      echo KILLED; return
    fi
    sleep 15
  done
  if wait "$bpid"; then echo BUILT; else echo FAIL; fi
}

# gate: wait while training active, up to MAX_WAIT. returns 0=go, 1=defer
gate() {
  local waited=0
  while :; do
    [ -x "$SENTINEL" ] || return 0
    if "$SENTINEL" >/dev/null 2>&1; then return 0; fi
    [ "$waited" -ge "$MAX_WAIT" ] && return 1
    echo "$(date '+%H:%M:%S') gated ($($SENTINEL)) waited=${waited}s" >>"$LOG"
    sleep "$GATE_SLEEP"; waited=$((waited+GATE_SLEEP))
  done
}

{ echo "# ten-proofs build status"; echo
  echo "mini (M4, 16GB) · Lean 4.32.0 + mathlib cached · training-aware sequential (\`nice -15\`, sentinel-gated, mem watchdog)."; echo
  echo "| # | target | result | time | sorry/admit |"; echo "|---|---|---|---|---|"; } > "$REPORT"

declare -a DEFERRED=()
i=0
run_one() {
  local t=$1 pass=$2
  local free; free=$(df -k / | awk 'END{print $4}')
  if [ "$free" -lt "$DISK_MIN_KB" ]; then echo "$(date '+%H:%M:%S') ABORT disk<4G" >>"$LOG"; return 9; fi
  if ! gate; then
    echo "$(date '+%H:%M:%S') DEFER $t (training sustained > ${MAX_WAIT}s)" >>"$LOG"
    return 1
  fi
  local s; s=$(sorries "$t")
  echo "$(date '+%H:%M:%S') [$pass] building $t (sorry=$s)" >>"$LOG"
  local start res dur; start=$(date +%s); res=$(build_watched "$t"); dur=$(( $(date +%s)-start ))
  echo "$(date '+%H:%M:%S') $t -> $res ${dur}s disk=$(df -h / | awk 'END{print $4}')" >>"$LOG"
  case "$res" in
    BUILT) printf "| %s | %s | ✅ built | %ss | %s |\n" "$((++i))" "$t" "$dur" "$s" >>"$REPORT" ;;
    FAIL)  printf "| %s | %s | ❌ FAIL | %ss | %s |\n" "$((++i))" "$t" "$dur" "$s" >>"$REPORT" ;;
    KILLED) return 1 ;;
  esac
  return 0
}

for t in $TARGETS; do run_one "$t" pass1 || { [ $? -eq 9 ] && break; DEFERRED+=("$t"); }; done
# second pass for deferred (training may have finished)
for t in "${DEFERRED[@]:-}"; do [ -n "$t" ] || continue; run_one "$t" pass2 || printf "| - | %s | ⏸ deferred | | %s |\n" "$t" "$(sorries "$t")" >>"$REPORT"; done

{ echo; echo "_Generated $(date '+%Y-%m-%d %H:%M'). Deferred = training stayed busy; rerun when idle._"; } >> "$REPORT"
echo "SWEEP-DONE $(date '+%H:%M:%S')" >> "$LOG"
