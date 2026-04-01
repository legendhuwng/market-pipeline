#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 05_rabbitmq_depth.sh
# Monitor RabbitMQ queue depth + stress ETL queue trực tiếp
#
# Hai mode:
#   Mode A (--observe) : Chỉ observe queue depth trong khi chạy
#                        load test khác, không inject thêm message
#   Mode B (--stress)  : Inject trực tiếp staging jobs vào RabbitMQ
#                        (bypass Kafka) để stress ETL Worker thuần túy
#
# Dùng:
#   bash 05_rabbitmq_depth.sh --observe 60    # quan sát 60 giây
#   bash 05_rabbitmq_depth.sh --stress        # stress ETL trực tiếp
# ─────────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

MODE="${1:---observe}"
OBS_DURATION="${2:-60}"

RESULT_DIR="results/$(date '+%Y%m%d_%H%M%S')_rabbit"
mkdir -p "$RESULT_DIR"

DEPTH_CSV="${RESULT_DIR}/queue_depth.csv"
echo "time,etl_staging_ready,etl_staging_unacked,etl_staging_total,etl_staging_in_rate,etl_staging_out_rate,etl_dlq,cache_invalidate,etl_success,etl_failed,etl_avg_ms" \
  > "$DEPTH_CSV"

# ── Helper: lấy queue detail đầy đủ ─────────────────────────
queue_detail() {
  local q="$1"
  curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "${RABBIT_API}/queues/%2F/${q}" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
ms=d.get('message_stats',{})
print('{},{},{},{},{},{}'.format(
  d.get('messages_ready',0),
  d.get('messages_unacked',0),
  d.get('messages',0),
  round(ms.get('publish_details',{}).get('rate',0),2),
  round(ms.get('deliver_get_details',{}).get('rate',0),2),
  d.get('name','?'),
))" 2>/dev/null || echo "0,0,0,0,0,${q}"
}

etl_job_quick() {
  curl -sf "${ETL_URL}/jobs/stats" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
avg=d.get('avgDurationMs','?')
# Strip 'ms' nếu có
avg=str(avg).replace('ms','').strip()
print('{},{},{}'.format(d.get('success',0),d.get('failed',0),avg)
)" 2>/dev/null || echo "?,?,?"
}

# ── Snapshot 1 lần ───────────────────────────────────────────
do_snapshot() {
  local stg; stg=$(queue_detail "etl.staging")
  local dlq_count; dlq_count=$(curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "${RABBIT_API}/queues/%2F/etl.staging.dlq" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages',0))" 2>/dev/null || echo 0)
  local cache_count; cache_count=$(curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "${RABBIT_API}/queues/%2F/cache.invalidate" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages',0))" 2>/dev/null || echo 0)
  local etl_jobs; etl_jobs=$(etl_job_quick)

  local stg_ready stg_unacked stg_total stg_in stg_out _name
  IFS=',' read -r stg_ready stg_unacked stg_total stg_in stg_out _name <<< "$stg"

  local ts; ts=$(date '+%H:%M:%S')
  printf "[%s] staging: ready=%-5s unacked=%-4s total=%-5s in=%-6s out=%-6s | dlq=%-3s cache=%-3s | etl_ok/fail=%s\n" \
    "$ts" "$stg_ready" "$stg_unacked" "$stg_total" \
    "${stg_in}/s" "${stg_out}/s" "$dlq_count" "$cache_count" "$etl_jobs"

  # Cảnh báo
  if [[ "$stg_ready" =~ ^[0-9]+$ ]]; then
    if (( stg_ready > 200 )); then
      err "  ⚠ ETL BACKLOG=${stg_ready} – ETL Worker đang bị overload!"
    elif (( stg_ready > 50 )); then
      warn "  △ etl.staging backlog=${stg_ready} – đang tích lũy"
    fi
  fi
  if [[ "$dlq_count" =~ ^[0-9]+$ && $dlq_count -gt 0 ]]; then
    err "  ⚠ DLQ=${dlq_count} – có job fail! Dùng: curl -X POST ${ETL_URL}/jobs/reprocess-dlq"
  fi

  # Lưu CSV
  csv_append "$DEPTH_CSV" \
    "$stg_ready" "$stg_unacked" "$stg_total" "$stg_in" "$stg_out" \
    "$dlq_count" "$cache_count" "$etl_jobs"
}

# ════════════════════════════════════════════════════════════
# MODE A: OBSERVE
# ════════════════════════════════════════════════════════════
mode_observe() {
  h1 "Mode OBSERVE – Theo dõi queue depth ${OBS_DURATION}s"
  info "  Chạy song song với load test khác"
  info "  Ctrl+C để dừng sớm"
  echo ""

  local end=$(( $(date +%s) + OBS_DURATION ))
  while (( $(date +%s) < end )); do
    do_snapshot
    sleep 3
  done

  h1 "Queue depth history"
  print_table "$DEPTH_CSV"
  log "Output: ${RESULT_DIR}/queue_depth.csv"
}

# ════════════════════════════════════════════════════════════
# MODE B: STRESS ETL TRỰC TIẾP
# Inject StagingJobMessage thẳng vào etl.staging (bypass Kafka)
# Mục tiêu: tìm max throughput của ETL Worker thuần túy
# ════════════════════════════════════════════════════════════
mode_stress() {
  h1 "Mode STRESS – Inject trực tiếp vào etl.staging"
  info "  Bypass Kafka, stress ETL Worker trực tiếp"
  info "  Dùng HTTP API của ETL Worker để reprocess job"
  echo ""

  # Lấy danh sách time bucket gần đây có data trong raw_trade
  log "Lấy time buckets có data trong raw_trade..."
  local buckets
  buckets=$(docker exec "${MYSQL_CONTAINER}" \
    mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -e "
      SELECT DISTINCT
        symbol,
        DATE_FORMAT(DATE_FORMAT(event_time, '%Y-%m-%dT%H:%i:00'), '%Y-%m-%dT%H:%i:00') AS bucket
      FROM market_raw.raw_trade
      ORDER BY bucket DESC
      LIMIT 30;" 2>/dev/null || echo "")

  if [[ -z "$buckets" ]]; then
    warn "Không có data trong raw_trade. Chạy 01_ingest_breakpoint.sh trước."
    return
  fi

  # Gửi job qua JobControlController (reprocess manual)
  # hoặc inject trực tiếp vào RabbitMQ qua Management API HTTP
  local STRESS_LEVELS=(5 10 20 40)
  local STRESS_DUR=15

  local STRESS_CSV="${RESULT_DIR}/etl_stress.csv"
  echo "workers,duration_s,jobs_injected,etl_total_before,etl_total_after,jobs_processed,etl_avg_ms" \
    > "$STRESS_CSV"

  for W in "${STRESS_LEVELS[@]}"; do
    log "Stress level: ${W} concurrent job injectors × ${STRESS_DUR}s"

    local etl_before; etl_before=$(curl -sf "${ETL_URL}/jobs/stats" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)

    local deadline=$(( $(date +%s) + STRESS_DUR ))
    local injected=0
    local job_pids=()

    # Worker: publish StagingJobMessage vào etl.staging qua RabbitMQ Management API
    _inject_worker() {
      local dl="$1"
      while (( $(date +%s) < dl )); do
        local sym="${SYMBOLS[$(( RANDOM % ${#SYMBOLS[@]} ))]}"
        # Lấy bucket ngẫu nhiên từ danh sách có data
        local bucket_line
        bucket_line=$(echo "$buckets" | awk "NR==$(( RANDOM % 30 + 1 ))")
        local bucket_sym; bucket_sym=$(echo "$bucket_line" | awk '{print $1}')
        local bucket_ts; bucket_ts=$(echo "$bucket_line" | awk '{print $2}')
        [[ -z "$bucket_ts" ]] && bucket_ts="2026-01-01T00:00:00"

        local job_id; job_id=$(gen_uuid)
        local msg="{\"jobId\":\"${job_id}\",\"type\":\"BUILD_STAGING_1M\",\"symbol\":\"${bucket_sym:-VCB}\",\"timeBucket\":\"${bucket_ts}\"}"

        # Publish qua RabbitMQ HTTP API
        curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
          -X POST "${RABBIT_API}/exchanges/%2F//publish" \
          -H "Content-Type: application/json" \
          -d "{
            \"routing_key\": \"etl.staging\",
            \"payload\": $(echo "$msg" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
            \"payload_encoding\": \"string\",
            \"properties\": {
              \"content_type\": \"application/json\",
              \"delivery_mode\": 2,
              \"headers\": {\"__TypeId__\": \"com.market.etl.model.StagingJobMessage\"}
            }
          }" -o /dev/null 2>/dev/null
        sleep 0.1
      done
    }

    for (( i=0; i<W; i++ )); do
      _inject_worker "$deadline" &
      job_pids+=($!)
    done

    # Monitor
    local e=0
    while (( $(date +%s) < deadline )); do
      do_snapshot
      sleep 3; e=$(( e+3 ))
    done

    for pid in "${job_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    sleep 3

    local etl_after; etl_after=$(curl -sf "${ETL_URL}/jobs/stats" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo 0)
    local etl_avg; etl_avg=$(curl -sf "${ETL_URL}/jobs/stats" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('avgDurationMs','?'))" 2>/dev/null || echo "?")
    local processed=$(( etl_after - etl_before ))

    printf "  Level %d: processed=%d in %ds = %.1f jobs/s | etl_avg=%s\n" \
      "$W" "$processed" "$STRESS_DUR" \
      "$(echo "scale=1; $processed / $STRESS_DUR" | bc)" "$etl_avg"

    csv_append "$STRESS_CSV" "$W" "$STRESS_DUR" "?" "$etl_before" "$etl_after" "$processed" "$etl_avg"
    sleep 5
  done

  h1 "ETL Stress kết quả"
  print_table "$STRESS_CSV"

  echo ""
  log "Replay DLQ nếu có lỗi: curl -X POST ${ETL_URL}/jobs/reprocess-dlq"
}

# ════════════════════════════════════════════════════════════
# DISPATCH
# ════════════════════════════════════════════════════════════
case "$MODE" in
  --observe|-o)  mode_observe ;;
  --stress|-s)   mode_stress  ;;
  *)
    echo "Usage:"
    echo "  bash 05_rabbitmq_depth.sh --observe [seconds]   # observe queue depth"
    echo "  bash 05_rabbitmq_depth.sh --stress              # stress ETL directly"
    exit 1
    ;;
esac
