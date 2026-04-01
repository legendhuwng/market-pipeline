#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 03_etl_pipeline.sh
# Đo ETL pipeline end-to-end + monitor Kafka lag + RabbitMQ depth
#
# 3 giai đoạn tải (steady-state, không ramping):
#   LOW  –  20 events/s  →  ETL nên xử lý thoải mái
#   MID  – 100 events/s  →  bắt đầu thấy queue depth
#   HIGH – 300 events/s  →  stress, tìm điểm lag tăng không ngừng
#
# Metrics chính:
#   - Ingest throughput thực tế (RPS)
#   - Kafka consumer lag (raw-consumer-group)
#   - RabbitMQ etl.staging depth (tăng = ETL bị bottleneck)
#   - ETL job success rate + avg duration
#   - E2E latency: ingest → xuất hiện trong /api/stocks
# ─────────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

STAGE_DURATION=60     # giây mỗi giai đoạn
POLL_INTERVAL=5       # giây giữa các lần snapshot
E2E_SAMPLE=5          # số event dùng để đo e2e latency mỗi stage
E2E_TIMEOUT=12        # giây chờ tối đa để event xuất hiện trong report

RESULT_DIR="results/$(date '+%Y%m%d_%H%M%S')_etl"
mkdir -p "$RESULT_DIR"

SNAPSHOT_CSV="${RESULT_DIR}/snapshots.csv"
E2E_CSV="${RESULT_DIR}/e2e_latency.csv"
echo "time,stage,target_rps,actual_rps,kafka_lag_total,rabbit_staging_ready,rabbit_dlq,etl_total,etl_success,etl_failed,etl_dlq,raw_rows,stg_rows,fact_rows" > "$SNAPSHOT_CSV"
echo "time,stage,symbol,e2e_ms,found" > "$E2E_CSV"

# ── Lấy JWT ────────────────────────────────────────────────
log "Lấy JWT token..."
TOKEN=$(get_token "user" "user123")
[[ -z "$TOKEN" ]] && { err "Không lấy được token"; exit 1; }
log "Token OK"

# ── Ingest worker: bắn đúng TPS target ────────────────────
# Dùng sleep để rate-limit: 1 worker = 1 req/s
# N workers = N req/s (thô, không chính xác tuyệt đối nhưng đủ cho bash)
_ingest_worker() {
  local deadline="$1"
  while (( $(date +%s) < deadline )); do
    local payload; payload=$(random_trade)
    curl -sf -X POST "${INGEST_URL}/api/trades" \
      -H "Content-Type: application/json" \
      --max-time 3 --connect-timeout 2 \
      -d "$payload" -o /dev/null 2>/dev/null
    sleep 1
  done
}

# ── Đo E2E latency cho 1 event ────────────────────────────
measure_e2e() {
  local stage="$1"
  local sym="${SYMBOLS[$(( RANDOM % ${#SYMBOLS[@]} ))]}"

  # Lấy số fact rows hiện tại
  local before; before=$(mysql_count "market_dw" "fact_market_1m")

  local t0; t0=$(date +%s%3N)
  # Inject event
  local payload; payload=$(random_trade)
  curl -sf -X POST "${INGEST_URL}/api/trades" \
    -H "Content-Type: application/json" \
    -d "$payload" -o /dev/null 2>/dev/null

  # Poll report service
  local deadline=$(( $(date +%s) + E2E_TIMEOUT ))
  local found=false
  while (( $(date +%s) < deadline )); do
    sleep 1
    local after; after=$(mysql_count "market_dw" "fact_market_1m")
    # Nếu fact rows tăng = ETL đã xử lý ít nhất 1 event mới
    if [[ "$after" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ ]] && \
       (( after > before )); then
      found=true
      break
    fi
    # Hoặc check qua Report API (cache có thể che)
    local resp
    resp=$(curl -sf \
      -H "Authorization: Bearer ${TOKEN}" \
      "${REPORT_URL}/api/stocks?symbol=${sym}&size=5" 2>/dev/null)
    if echo "$resp" | grep -q '"content":\[{'; then
      found=true
      break
    fi
  done

  local t1; t1=$(date +%s%3N)
  local ms=$(( t1 - t0 ))
  csv_append "$E2E_CSV" "$stage" "$sym" "$ms" "$found"
  echo "  E2E: symbol=${sym} found=${found} latency=${ms}ms"
}

# ── Snapshot tất cả metrics ────────────────────────────────
snapshot_all() {
  local stage="$1" target_rps="$2" actual_rps="$3"

  # Kafka lag
  local kafka_lag_total=0
  kafka_lag_total=$(docker exec "${KAFKA_CONTAINER}" \
    kafka-consumer-groups --bootstrap-server localhost:9092 \
    --describe --group raw-consumer-group 2>/dev/null \
  | awk 'NR>1 && $6 ~ /^[0-9]+$/ {sum+=$6} END{print sum+0}' || echo 0)

  # RabbitMQ
  local rb_stg_ready rb_dlq
  rb_stg_ready=$(curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "${RABBIT_API}/queues/%2F/etl.staging" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages_ready',0))" 2>/dev/null || echo 0)
  rb_dlq=$(curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "${RABBIT_API}/queues/%2F/etl.staging.dlq" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo 0)

  # ETL job stats
  local etl_total etl_success etl_failed etl_dlq
  eval "$(curl -sf "${ETL_URL}/jobs/stats" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('etl_total={} etl_success={} etl_failed={} etl_dlq={}'.format(
  d.get('total',0), d.get('success',0), d.get('failed',0), d.get('dlqMessages',0)))" 2>/dev/null \
    || echo "etl_total=? etl_success=? etl_failed=? etl_dlq=?")"

  # MySQL row counts
  local raw_rows; raw_rows=$(mysql_count "market_raw" "raw_trade")
  local stg_rows; stg_rows=$(mysql_count "market_staging" "stg_trade_1m")
  local fact_rows; fact_rows=$(mysql_count "market_dw" "fact_market_1m")

  # In snapshot
  printf "  [%s] stage=%-5s rps=%s/%s | kafka_lag=%-6s rabbit=%-4s dlq=%-3s | raw=%-8s stg=%-6s fact=%-6s | etl=%s/%s fail=%s\n" \
    "$(date '+%H:%M:%S')" "$stage" "$actual_rps" "$target_rps" \
    "$kafka_lag_total" "$rb_stg_ready" "$rb_dlq" \
    "$raw_rows" "$stg_rows" "$fact_rows" \
    "$etl_success" "$etl_total" "$etl_failed"

  # Cảnh báo bottleneck
  if [[ "$rb_stg_ready" =~ ^[0-9]+$ ]] && (( rb_stg_ready > 50 )); then
    warn "  ⚠ RabbitMQ etl.staging backlog=${rb_stg_ready} → ETL đang không kịp!"
  fi
  if [[ "$kafka_lag_total" =~ ^[0-9]+$ ]] && (( kafka_lag_total > 500 )); then
    warn "  ⚠ Kafka consumer lag=${kafka_lag_total} → raw-consumer chậm!"
  fi
  if [[ "$rb_dlq" =~ ^[0-9]+$ ]] && (( rb_dlq > 0 )); then
    warn "  ⚠ DLQ=${rb_dlq} message – có ETL job đang fail!"
  fi

  csv_append "$SNAPSHOT_CSV" "$stage" "$target_rps" "$actual_rps" \
    "$kafka_lag_total" "$rb_stg_ready" "$rb_dlq" \
    "$etl_total" "$etl_success" "$etl_failed" "$etl_dlq" \
    "$raw_rows" "$stg_rows" "$fact_rows"
}

# ── Chạy một stage ─────────────────────────────────────────
run_stage() {
  local stage_name="$1" target_rps="$2"
  h1 "Stage: ${stage_name} – ${target_rps} events/s"

  local deadline=$(( $(date +%s) + STAGE_DURATION ))
  local pids=()

  # Spawn N workers = N req/s
  for (( i=0; i<target_rps; i++ )); do
    _ingest_worker "$deadline" &
    pids+=($!)
    # Throttle spawning để tránh fork bomb
    (( i % 20 == 19 )) && sleep 0.5
  done

  log "Spawned ${target_rps} workers, chạy trong ${STAGE_DURATION}s..."

  # Lấy count trước để tính actual RPS
  local count_before; count_before=$(mysql_count "market_raw" "raw_trade")
  local t_start; t_start=$(date +%s)

  # E2E samples trong giai đoạn đầu
  log "Đo E2E latency (${E2E_SAMPLE} samples)..."
  for (( s=0; s<E2E_SAMPLE; s++ )); do
    measure_e2e "$stage_name"
    sleep 2
  done

  # Snapshot loop
  local elapsed=0
  while (( $(date +%s) < deadline )); do
    local count_now; count_now=$(mysql_count "market_raw" "raw_trade")
    local t_now; t_now=$(date +%s)
    local actual_rps=0
    if [[ "$count_now" =~ ^[0-9]+$ && "$count_before" =~ ^[0-9]+$ ]]; then
      local elapsed_s=$(( t_now - t_start ))
      [[ $elapsed_s -gt 0 ]] && \
        actual_rps=$(echo "scale=1; ($count_now - $count_before) / $elapsed_s" | bc)
    fi
    snapshot_all "$stage_name" "$target_rps" "$actual_rps"
    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
  done

  # Kill workers
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  log "Stage ${stage_name} xong. Cool-down 10s..."
  sleep 10
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
h1 "TEST 03 – ETL Pipeline E2E Throughput + Kafka/RabbitMQ Monitor"
info "  Stage LOW   :  20 events/s  × ${STAGE_DURATION}s"
info "  Stage MID   : 100 events/s  × ${STAGE_DURATION}s"
info "  Stage HIGH  : 300 events/s  × ${STAGE_DURATION}s"
info "  Output dir  : ${RESULT_DIR}"
echo ""

# Snapshot baseline
log "=== BASELINE ==="
snapshot_all "baseline" "0" "0"
echo ""

run_stage "LOW"  20
run_stage "MID"  100
run_stage "HIGH" 300

# ── Snapshot cuối ─────────────────────────────────────────
log "=== FINAL SNAPSHOT ==="
snapshot_all "final" "0" "0"

# ── Tổng kết ─────────────────────────────────────────────
h1 "Bảng snapshot theo thời gian"
print_table "$SNAPSHOT_CSV"

echo ""
h1 "E2E latency samples"
print_table "$E2E_CSV"

# E2E stats
echo ""
log "E2E latency thống kê:"
python3 - "$E2E_CSV" << 'PYEOF'
import sys, csv, statistics
rows = list(csv.DictReader(open(sys.argv[1])))
for stage in ['LOW','MID','HIGH']:
    ms_list = [int(r['e2e_ms']) for r in rows if r['stage']==stage and r['found']=='true']
    missed  = sum(1 for r in rows if r['stage']==stage and r['found']=='false')
    if ms_list:
        print(f"  {stage:<6} n={len(ms_list)} min={min(ms_list)}ms avg={statistics.mean(ms_list):.0f}ms "
              f"p95={sorted(ms_list)[int(len(ms_list)*0.95)]if len(ms_list)>1 else ms_list[0]}ms "
              f"max={max(ms_list)}ms  missed={missed}")
    else:
        print(f"  {stage:<6} no successful samples (missed={missed})")
PYEOF

echo ""
log "Output lưu tại: ${RESULT_DIR}/"
log "Replay DLQ nếu cần: curl -X POST ${ETL_URL}/jobs/reprocess-dlq"
