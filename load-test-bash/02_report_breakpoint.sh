#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 02_report_breakpoint.sh
# Tìm breaking point của Report Service (GET /api/stocks)
#
# Hai phase:
#   Phase A – Cache HIT  : query đơn giản ?symbol=X (Redis hit)
#   Phase B – Cache MISS : query có ?from=...&to=... (luôn hit DB)
#
# Breaking point riêng từng phase:
#   Cache HIT  : p99 > 100ms hoặc error > 1%
#   Cache MISS : p99 > 800ms hoặc error > 1%
# ─────────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

DURATION=20
LEVELS=(1 5 10 20 50 100 200 300 400)
RESULT_DIR="results/$(date '+%Y%m%d_%H%M%S')_report"
mkdir -p "$RESULT_DIR"

# ── Lấy JWT một lần, dùng chung ─────────────────────────────
log "Đăng nhập lấy JWT token..."
TOKEN=$(get_token "user" "user123")
if [[ -z "$TOKEN" ]]; then
  err "Không lấy được token. Report Service đang chạy chưa?"
  exit 1
fi
log "Token OK (${#TOKEN} chars)"
echo ""

# ── Worker cache HIT: query đơn giản theo symbol ─────────────
_worker_hit() {
  local out="$1" deadline="$2"
  local sym="${SYMBOLS[$(( RANDOM % ${#SYMBOLS[@]} ))]}"
  while (( $(date +%s) < deadline )); do
    local t0; t0=$(date +%s%N)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 --connect-timeout 3 \
      -H "Authorization: Bearer ${TOKEN}" \
      "${REPORT_URL}/api/stocks?symbol=${sym}&size=20" 2>/dev/null)
    local ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    echo "${code} ${ms}" >> "$out"
  done
}

# ── Worker cache MISS: query có filter thời gian ─────────────
_worker_miss() {
  local out="$1" deadline="$2"
  local sym="${SYMBOLS[$(( RANDOM % ${#SYMBOLS[@]} ))]}"
  # from = 1 giờ trước, buộc skip cache
  local from; from=$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
    || date -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
    || echo "2026-01-01T00:00:00")
  local to; to=$(date '+%Y-%m-%dT%H:%M:%S')
  while (( $(date +%s) < deadline )); do
    local t0; t0=$(date +%s%N)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 --connect-timeout 3 \
      -H "Authorization: Bearer ${TOKEN}" \
      "${REPORT_URL}/api/stocks?symbol=${sym}&from=${from}&to=${to}&size=10" 2>/dev/null)
    local ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    echo "${code} ${ms}" >> "$out"
  done
}

# ── Aggregate helper ──────────────────────────────────────────
aggregate() {
  local dir="$1" workers="$2" phase="$3"
  local all="${dir}/all.tmp"
  cat "${dir}"/w*.tmp 2>/dev/null | sort -n -k2 > "$all"

  local total ok errors
  total=$(wc -l < "$all" 2>/dev/null || echo 0)
  ok=$(grep -c '^200 ' "$all" 2>/dev/null || echo 0)
  errors=$(( total - ok ))
  local error_pct=0
  [[ $total -gt 0 ]] && error_pct=$(echo "scale=2; $errors*100/$total" | bc)
  local rps=0
  [[ $DURATION -gt 0 ]] && rps=$(echo "scale=1; $total/$DURATION" | bc)

  local lats; lats=$(awk '{print $2}' "$all" | sort -n)
  local min_ms=0 avg_ms=0 max_ms=0 p95_ms=0 p99_ms=0
  if [[ $total -gt 0 ]]; then
    min_ms=$(echo "$lats" | head -1)
    max_ms=$(echo "$lats" | tail -1)
    avg_ms=$(echo "$lats" | awk '{s+=$1}END{printf "%.0f",s/NR}')
    local i95=$(( total*95/100 )); [[ $i95 -lt 1 ]] && i95=1
    local i99=$(( total*99/100 )); [[ $i99 -lt 1 ]] && i99=1
    p95_ms=$(echo "$lats" | sed -n "${i95}p")
    p99_ms=$(echo "$lats" | sed -n "${i99}p")
  fi

  printf "  │  %-12s Workers=%-5d Req=%-6d Err=%s%%  RPS=%s\n" \
    "$phase" "$workers" "$total" "$error_pct" "$rps"
  printf "  │  %-12s min=%-5s avg=%-5s p95=%-5s p99=%-5s max=%s ms\n" \
    "" "$min_ms" "$avg_ms" "$p95_ms" "$p99_ms" "$max_ms"

  # Trả kết quả ra stdout để caller bắt
  echo "RESULT:${total}:${ok}:${errors}:${error_pct}:${rps}:${min_ms}:${avg_ms}:${p95_ms}:${p99_ms}:${max_ms}"
}

# ── Chạy một level, cả 2 phase ────────────────────────────────
run_level() {
  local workers="$1"
  log "Level ${workers} workers..."

  local deadline=$(( $(date +%s) + DURATION ))

  # Spawn workers HIT + MISS song song (nửa nửa)
  local hit_dir; hit_dir=$(mktemp -d)
  local miss_dir; miss_dir=$(mktemp -d)
  local hit_pids=() miss_pids=()

  local hit_w=$(( workers / 2 )); [[ $hit_w -lt 1 ]] && hit_w=1
  local miss_w=$(( workers - hit_w )); [[ $miss_w -lt 1 ]] && miss_w=1

  for (( i=0; i<hit_w; i++  )); do _worker_hit  "${hit_dir}/w${i}.tmp"  "$deadline" & hit_pids+=($!);  done
  for (( i=0; i<miss_w; i++ )); do _worker_miss "${miss_dir}/w${i}.tmp" "$deadline" & miss_pids+=($!); done

  # Progress
  local e=0
  while (( e < DURATION )); do
    local n_hit;  n_hit=$(cat  "${hit_dir}"/*.tmp  2>/dev/null | wc -l)
    local n_miss; n_miss=$(cat "${miss_dir}"/*.tmp 2>/dev/null | wc -l)
    printf "\r  → %ds | HIT=%d MISS=%d" "$e" "$n_hit" "$n_miss"
    sleep 2; e=$(( e+2 ))
  done; printf "\n"

  for pid in "${hit_pids[@]}"  "${miss_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  echo "  ┌─────────────────────────────────────────────────────┐"
  local hit_result;  hit_result=$(aggregate  "$hit_dir"  "$hit_w"  "CACHE HIT")
  local miss_result; miss_result=$(aggregate "$miss_dir" "$miss_w" "CACHE MISS")
  echo "  └─────────────────────────────────────────────────────┘"

  rm -rf "$hit_dir" "$miss_dir"

  # Parse để ghi CSV và detect break
  local hit_data;  hit_data=$(echo  "$hit_result"  | grep '^RESULT:')
  local miss_data; miss_data=$(echo "$miss_result" | grep '^RESULT:')

  IFS=: read -r _ ht_total ht_ok ht_err ht_epct ht_rps ht_min ht_avg ht_p95 ht_p99 ht_max <<< "$hit_data"
  IFS=: read -r _ ms_total ms_ok ms_err ms_epct ms_rps ms_min ms_avg ms_p95 ms_p99 ms_max <<< "$miss_data"

  local HIT_CSV="${RESULT_DIR}/hit_summary.csv"
  local MISS_CSV="${RESULT_DIR}/miss_summary.csv"
  [[ ! -f "$HIT_CSV"  ]] && echo "workers,total,ok,errors,error_pct,rps,min_ms,avg_ms,p95_ms,p99_ms,max_ms" > "$HIT_CSV"
  [[ ! -f "$MISS_CSV" ]] && echo "workers,total,ok,errors,error_pct,rps,min_ms,avg_ms,p95_ms,p99_ms,max_ms" > "$MISS_CSV"
  csv_append "$HIT_CSV"  "$workers" "$ht_total" "$ht_ok" "$ht_err" "$ht_epct" "$ht_rps" "$ht_min" "$ht_avg" "$ht_p95" "$ht_p99" "$ht_max"
  csv_append "$MISS_CSV" "$workers" "$ms_total" "$ms_ok" "$ms_err" "$ms_epct" "$ms_rps" "$ms_min" "$ms_avg" "$ms_p95" "$ms_p99" "$ms_max"

  # Detect breaking point
  local status="ok"
  local hit_break=false miss_break=false

  # HIT threshold: p99 > 200ms hoặc error > 1%
  if [[ -n "$ht_p99" && "$ht_p99" -gt 200 ]] || \
     (( $(echo "${ht_epct:-0} > 1" | bc -l 2>/dev/null || echo 0) )); then
    hit_break=true
    warn "△ Cache HIT degraded: p99=${ht_p99}ms error=${ht_epct}%"
  fi
  # MISS threshold: p99 > 1000ms hoặc error > 1%
  if [[ -n "$ms_p99" && "$ms_p99" -gt 1000 ]] || \
     (( $(echo "${ms_epct:-0} > 1" | bc -l 2>/dev/null || echo 0) )); then
    miss_break=true
    warn "△ Cache MISS (DB) degraded: p99=${ms_p99}ms error=${ms_epct}%"
  fi

  if $hit_break && $miss_break; then
    status="break"
    err "BREAKING POINT: cả cache HIT và MISS đều vỡ tại ${workers} workers"
  elif $hit_break || $miss_break; then
    status="warn"
  fi

  echo "$status"
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
h1 "TEST 02 – Report Service Breaking Point (Cache HIT vs DB MISS)"
info "  Target    : ${REPORT_URL}/api/stocks"
info "  Split     : 50% cache-hit query / 50% cache-miss (DB) query"
info "  Duration  : ${DURATION}s per level"
echo ""

log "Redis stats trước test:"
redis_stats
echo ""

FOUND_BREAK=false
for W in "${LEVELS[@]}"; do
  status=$(run_level "$W")
  sleep 3
  if [[ "$status" == "break" ]]; then
    FOUND_BREAK=true
    break
  fi
done

h1 "Bảng kết quả – Cache HIT"
print_table "${RESULT_DIR}/hit_summary.csv"

echo ""
h1 "Bảng kết quả – Cache MISS (DB query)"
print_table "${RESULT_DIR}/miss_summary.csv"

echo ""
log "Redis stats sau test:"
redis_stats

echo ""
if [[ "$FOUND_BREAK" == true ]]; then
  info "Breaking point tìm thấy – xem bảng trên"
else
  info "Service chịu được tới ${LEVELS[-1]} workers"
fi
log "Output: ${RESULT_DIR}/"
