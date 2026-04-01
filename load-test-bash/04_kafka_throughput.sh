#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 04_kafka_throughput.sh
# Đo throughput thực tế của Kafka topic market.trades
#
# Cách hoạt động:
#   1. Bắn N events liên tục trong DURATION giây
#   2. Đọc Kafka consumer group offset trước và sau
#   3. Tính: produced msgs/s, consumed msgs/s, lag tăng hay giảm
#
# Không cần kafka-perf-test – dùng curl + docker exec kafka CLI
# ─────────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

DURATION=45        # giây mỗi level
LEVELS=(10 50 100 200 400 600)   # số concurrent sender

RESULT_DIR="results/$(date '+%Y%m%d_%H%M%S')_kafka"
mkdir -p "$RESULT_DIR"

SUMMARY_CSV="${RESULT_DIR}/kafka_summary.csv"
echo "level_workers,duration_s,produced,consumed,final_lag,produce_rps,consume_rps,lag_trend" > "$SUMMARY_CSV"

# ── Lấy tổng offset đã committed của consumer group ───────────
get_consumer_offset() {
  docker exec "${KAFKA_CONTAINER}" \
    kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --describe --group raw-consumer-group 2>/dev/null \
  | awk 'NR>1 && $5 ~ /^[0-9]+$/ {sum+=$5} END{print sum+0}'
}

# ── Lấy tổng lag hiện tại ─────────────────────────────────────
get_total_lag() {
  docker exec "${KAFKA_CONTAINER}" \
    kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --describe --group raw-consumer-group 2>/dev/null \
  | awk 'NR>1 && $6 ~ /^[0-9]+$/ {sum+=$6} END{print sum+0}'
}

# ── Lấy high-water mark (end offset) của topic ───────────────
get_end_offsets() {
  docker exec "${KAFKA_CONTAINER}" \
    kafka-run-class kafka.tools.GetOffsetShell \
    --broker-list localhost:9092 \
    --topic market.trades --time -1 2>/dev/null \
  | awk -F: '{sum+=$3} END{print sum+0}'
}

# ── Worker bắn event vào ingest ───────────────────────────────
_kafka_worker() {
  local deadline="$1"
  while (( $(date +%s) < deadline )); do
    curl -sf -X POST "${INGEST_URL}/api/trades" \
      -H "Content-Type: application/json" \
      --max-time 2 --connect-timeout 1 \
      -d "$(random_trade)" -o /dev/null 2>/dev/null
  done
}

# ── Chạy 1 level ─────────────────────────────────────────────
run_level() {
  local workers="$1"
  log "Level: ${workers} concurrent senders × ${DURATION}s"

  local deadline=$(( $(date +%s) + DURATION ))

  # Snapshot trước
  local off_before; off_before=$(get_end_offsets)
  local consumed_before; consumed_before=$(get_consumer_offset)
  local lag_before; lag_before=$(get_total_lag)

  log "  Before: end_offset=${off_before} consumed=${consumed_before} lag=${lag_before}"

  # Spawn workers
  local pids=()
  for (( i=0; i<workers; i++ )); do
    _kafka_worker "$deadline" &
    pids+=($!)
    # Tránh fork bomb
    (( i % 30 == 29 )) && sleep 0.2
  done

  # Monitor trong khi chạy
  local elapsed=0
  while (( $(date +%s) < deadline )); do
    local lag_now; lag_now=$(get_total_lag)
    local off_now; off_now=$(get_end_offsets)
    printf "\r  [%ds/%ds] end_offset=%-8s lag=%-6s" \
      "$elapsed" "$DURATION" "$off_now" "$lag_now"
    sleep 3; elapsed=$(( elapsed + 3 ))
  done; printf "\n"

  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true

  # Snapshot sau – chờ thêm 3s cho inflight
  sleep 3
  local off_after; off_after=$(get_end_offsets)
  local consumed_after; consumed_after=$(get_consumer_offset)
  local lag_after; lag_after=$(get_total_lag)

  # Tính toán
  local produced consumed_delta
  produced=$(( off_after - off_before )); [[ $produced -lt 0 ]] && produced=0
  consumed_delta=$(( consumed_after - consumed_before )); [[ $consumed_delta -lt 0 ]] && consumed_delta=0

  local produce_rps=0 consume_rps=0
  [[ $DURATION -gt 0 ]] && {
    produce_rps=$(echo "scale=1; $produced / $DURATION" | bc)
    consume_rps=$(echo "scale=1; $consumed_delta / $DURATION" | bc)
  }

  local lag_delta=$(( lag_after - lag_before ))
  local lag_trend="stable"
  [[ $lag_delta -gt 50   ]] && lag_trend="GROWING ↑ (+${lag_delta})"
  [[ $lag_delta -lt -50  ]] && lag_trend="shrinking ↓ (${lag_delta})"
  [[ $lag_delta -gt 500  ]] && lag_trend="CRITICAL ↑ (+${lag_delta}) – consumer không kịp!"

  # In kết quả
  echo ""
  echo "  ┌───────────────────────────────────────────────────────┐"
  printf  "  │  Senders   : %-5d  Duration: %ds\n"       "$workers" "$DURATION"
  printf  "  │  Produced  : %-8s msgs  ( %s msg/s )\n"   "$produced" "$produce_rps"
  printf  "  │  Consumed  : %-8s msgs  ( %s msg/s )\n"   "$consumed_delta" "$consume_rps"
  printf  "  │  Lag       : before=%-6s after=%-6s  %s\n" "$lag_before" "$lag_after" "$lag_trend"
  echo "  └───────────────────────────────────────────────────────┘"

  # Lưu CSV
  csv_append "$SUMMARY_CSV" \
    "$workers" "$DURATION" "$produced" "$consumed_delta" \
    "$lag_after" "$produce_rps" "$consume_rps" "$lag_trend"

  # Trả trạng thái
  if echo "$lag_trend" | grep -q "CRITICAL\|GROWING"; then
    echo "break"
  else
    echo "ok"
  fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
h1 "TEST 04 – Kafka Throughput (via Ingest → market.trades)"
info "  Topic    : market.trades (3 partitions)"
info "  Consumer : raw-consumer-group"
info "  Levels   : ${LEVELS[*]} concurrent senders"
echo ""

log "Baseline Kafka state:"
echo "  end_offsets : $(get_end_offsets)"
echo "  consumer lag: $(get_total_lag)"
echo ""

FOUND_BREAK=false

for W in "${LEVELS[@]}"; do
  status=$(run_level "$W")
  sleep 5  # cool-down

  if [[ "$status" == "break" ]]; then
    FOUND_BREAK=true
    warn "Kafka consumer lag đang tăng không kiểm soát tại ${W} senders"
    warn "→ Raw consumer không xử lý kịp (batch_size=200, concurrency=3)"
    break
  fi
done

h1 "Bảng tổng kết Kafka Throughput"
print_table "$SUMMARY_CSV"

echo ""
if [[ "$FOUND_BREAK" == true ]]; then
  echo ""
  info "Gợi ý khắc phục nếu lag tăng:"
  echo "  1. Tăng consumer.batch-size trong raw-consumer/application.yml (hiện 200)"
  echo "  2. Tăng factory.setConcurrency trong KafkaConsumerConfig (hiện 3)"
  echo "  3. Thêm partition Kafka (hiện 3) – cần restart kafka"
  echo "  4. Scale raw-consumer: chạy nhiều instance cùng group-id"
fi

log "Output: ${RESULT_DIR}/kafka_summary.csv"
