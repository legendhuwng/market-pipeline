#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 01_ingest_breakpoint.sh
# Tìm breaking point của Ingest Service (POST /api/trades)
#
# Chiến lược: ramping concurrency – tăng số process song song
#   Mỗi "level" chạy N worker, mỗi worker bắn liên tục trong DURATION giây
#   Đo: RPS thực tế, error rate, latency min/avg/max/p95/p99
#   Breaking point: error_rate > 1% HOẶC p99 > 500ms
#
# Chạy: bash 01_ingest_breakpoint.sh
# ─────────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

# ── Tham số ──────────────────────────────────────────────────
DURATION=20          # giây mỗi level
TARGET="${INGEST_URL}/api/trades"
RESULT_DIR="results/$(date '+%Y%m%d_%H%M%S')_ingest"
mkdir -p "$RESULT_DIR"

HEADER_CSV="time,level,workers,total_req,ok,errors,error_pct,rps,min_ms,avg_ms,p95_ms,p99_ms,max_ms"
SUMMARY_CSV="${RESULT_DIR}/summary.csv"
echo "$HEADER_CSV" > "$SUMMARY_CSV"

# Levels: số concurrent workers tăng dần
LEVELS=(1 5 10 20 50 100 150 200 300)

# ── Worker: bắn request liên tục trong DURATION giây ─────────
# Mỗi worker ghi kết quả ra file riêng (worker_<pid>.tmp)
_worker() {
  local out="$1" deadline="$2"
  while (( $(date +%s) < deadline )); do
    local payload
    payload=$(random_trade)
    local start_ns
    start_ns=$(date +%s%N)

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$TARGET" \
      -H "Content-Type: application/json" \
      --max-time 5 \
      --connect-timeout 3 \
      -d "$payload" 2>/dev/null)

    local end_ns
    end_ns=$(date +%s%N)
    local ms=$(( (end_ns - start_ns) / 1000000 ))

    echo "${http_code} ${ms}" >> "$out"
  done
}

# ── Chạy một level ───────────────────────────────────────────
run_level() {
  local workers="$1"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local deadline=$(( $(date +%s) + DURATION ))

  log "Level ${workers} workers – chạy ${DURATION}s..."

  # Spawn N background workers
  local pids=()
  for (( i=0; i<workers; i++ )); do
    _worker "${tmp_dir}/w${i}.tmp" "$deadline" &
    pids+=($!)
  done

  # Hiển thị progress
  local elapsed=0
  while (( elapsed < DURATION )); do
    local done_so_far
    done_so_far=$(cat "${tmp_dir}"/*.tmp 2>/dev/null | wc -l)
    printf "\r  → %ds / %ds  |  req so far: %d" "$elapsed" "$DURATION" "$done_so_far"
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done
  printf "\n"

  # Chờ tất cả worker xong
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  # ── Aggregate kết quả ──────────────────────────────────────
  local all_file="${tmp_dir}/all.tmp"
  cat "${tmp_dir}"/w*.tmp 2>/dev/null | sort -n -k2 > "$all_file"

  local total ok errors
  total=$(wc -l < "$all_file" 2>/dev/null || echo 0)
  ok=$(grep -c '^202 ' "$all_file" 2>/dev/null || echo 0)
  errors=$(( total - ok ))
  local error_pct=0
  [[ $total -gt 0 ]] && error_pct=$(echo "scale=2; $errors * 100 / $total" | bc)

  local rps=0
  [[ $DURATION -gt 0 ]] && rps=$(echo "scale=1; $total / $DURATION" | bc)

  # Latency stats từ cột thứ 2
  local latencies
  latencies=$(awk '{print $2}' "$all_file" | sort -n)

  local min_ms=0 avg_ms=0 max_ms=0 p95_ms=0 p99_ms=0
  if [[ $total -gt 0 ]]; then
    min_ms=$(echo "$latencies" | head -1)
    max_ms=$(echo "$latencies" | tail -1)
    avg_ms=$(echo "$latencies" | awk '{s+=$1}END{printf "%.0f", s/NR}')
    local p95_idx=$(( total * 95 / 100 ))
    local p99_idx=$(( total * 99 / 100 ))
    [[ $p95_idx -lt 1 ]] && p95_idx=1
    [[ $p99_idx -lt 1 ]] && p99_idx=1
    p95_ms=$(echo "$latencies" | sed -n "${p95_idx}p")
    p99_ms=$(echo "$latencies" | sed -n "${p99_idx}p")
  fi

  rm -rf "$tmp_dir"

  # In kết quả level
  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  printf  "  │  Workers : %-5d  Duration: %ds\n" "$workers" "$DURATION"
  printf  "  │  Requests: %-6d OK=%-5d ERR=%-5d (%.1f%%)\n" "$total" "$ok" "$errors" "$error_pct"
  printf  "  │  RPS     : %-8s\n" "$rps"
  printf  "  │  Latency : min=%-5s avg=%-5s p95=%-5s p99=%-5s max=%s ms\n" \
    "$min_ms" "$avg_ms" "$p95_ms" "$p99_ms" "$max_ms"
  echo "  └─────────────────────────────────────────────────────┘"

  # Lưu CSV
  csv_append "$SUMMARY_CSV" "$workers" "$workers" "$total" "$ok" "$errors" \
    "$error_pct" "$rps" "$min_ms" "$avg_ms" "$p95_ms" "$p99_ms" "$max_ms"

  # Trả về trạng thái: ok/warn/break
  local status="ok"
  if (( $(echo "$error_pct > 5" | bc -l) )) || [[ -n "$p99_ms" && "$p99_ms" != "0" && $p99_ms -gt 1000 ]]; then
    status="break"
    warn "⚠ BREAKING POINT ở ${workers} workers! error=${error_pct}% p99=${p99_ms}ms"
  elif (( $(echo "$error_pct > 1" | bc -l) )) || [[ -n "$p99_ms" && "$p99_ms" != "0" && $p99_ms -gt 500 ]]; then
    status="warn"
    warn "△ Bắt đầu xuất hiện stress ở ${workers} workers (error=${error_pct}% p99=${p99_ms}ms)"
  fi
  echo "$status"
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
h1 "TEST 01 – Ingest Service Breaking Point"
info "  Target   : ${TARGET}"
info "  Levels   : ${LEVELS[*]}"
info "  Duration : ${DURATION}s per level"
info "  Output   : ${RESULT_DIR}"
echo ""

# Warm-up: kiểm tra service đang chạy
log "Warm-up check..."
WU=$(curl -sf "${INGEST_URL}/api/health" 2>/dev/null || echo "")
if [[ -z "$WU" ]]; then
  err "Ingest Service không phản hồi tại ${INGEST_URL}/api/health"
  exit 1
fi
log "Service UP: $WU"
echo ""

FOUND_BREAK=false

for W in "${LEVELS[@]}"; do
  status=$(run_level "$W")
  sleep 3  # cool-down ngắn giữa các level

  if [[ "$status" == "break" ]]; then
    FOUND_BREAK=true
    warn "Dừng test – đã tìm thấy breaking point tại ${W} concurrent workers"
    break
  fi
done

# ── In bảng tổng kết ─────────────────────────────────────────
h1 "Kết quả tổng hợp"
print_table "$SUMMARY_CSV"

echo ""
if [[ "$FOUND_BREAK" == true ]]; then
  info "BREAKING POINT tìm thấy – xem dòng cuối bảng trên"
else
  info "Hệ thống chịu được toàn bộ các mức test (tối đa ${LEVELS[-1]} workers)"
fi

echo ""
log "Chi tiết lưu tại: ${RESULT_DIR}/summary.csv"

# Snapshot queue sau test
echo ""
log "RabbitMQ queue snapshot:"
rabbit_queue "etl.staging"
rabbit_queue "etl.staging.dlq"
