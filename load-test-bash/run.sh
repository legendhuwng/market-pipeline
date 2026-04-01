#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# run.sh  –  Orchestrator chính
# Chạy: bash run.sh [all|ingest|report|etl|kafka|rabbit]
# ─────────────────────────────────────────────────────────────
source "$(dirname "$0")/lib.sh"

TARGET="${1:-all}"
DIR="$(dirname "$0")"

# ── Kiểm tra prerequisites ────────────────────────────────────
preflight() {
  h1 "Kiểm tra hệ thống"

  local ok=true
  check_svc() {
    local name="$1" url="$2"
    if curl -sf --max-time 3 "$url" -o /dev/null 2>/dev/null; then
      log "✓ ${name}"
    else
      warn "✗ ${name} (${url})"
      ok=false
    fi
  }

  check_svc "Ingest  :8080" "${INGEST_URL}/api/health"
  check_svc "ETL     :8084" "${ETL_URL}/actuator/health"
  check_svc "Report  :8085" "${REPORT_URL}/api/health"
  check_svc "RabbitMQ:15672" "${RABBIT_API}/overview"
  check_svc "Generator:8081" "http://localhost:8081/generator/status"

  # Kiểm tra docker có sẵn không
  if ! command -v docker &>/dev/null; then
    warn "docker không có trong PATH – một số metrics sẽ không khả dụng"
  fi

  if [[ "$ok" == false ]]; then
    echo ""
    warn "Một số service chưa sẵn sàng."
    warn "Đảm bảo chạy: docker compose up -d"
    echo ""
    read -rp "Tiếp tục anyway? (y/N) " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
  fi

  # Tắt generator để test sạch
  log "Tắt Fake Generator..."
  curl -sf -X POST "http://localhost:8081/generator/stop" -o /dev/null 2>/dev/null || true
  sleep 2
  log "Generator tắt"
}

# Bật lại generator khi thoát
cleanup() {
  echo ""
  log "Bật lại Fake Generator..."
  curl -sf -X POST "http://localhost:8081/generator/start" -o /dev/null 2>/dev/null || true
  log "Done."
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────
preflight

echo ""
h1 "Bắt đầu Load Test – target: ${TARGET}"
START_TIME=$(date '+%H:%M:%S')

case "$TARGET" in
  ingest)
    bash "${DIR}/01_ingest_breakpoint.sh"
    ;;
  report)
    bash "${DIR}/02_report_breakpoint.sh"
    ;;
  etl)
    bash "${DIR}/03_etl_pipeline.sh"
    ;;
  kafka)
    bash "${DIR}/04_kafka_throughput.sh"
    ;;
  rabbit|rabbitmq)
    bash "${DIR}/05_rabbitmq_depth.sh" --observe 90
    ;;
  all)
    echo ""
    info "Thứ tự chạy:"
    info "  1. Ingest Service breaking point     (~5 phút)"
    info "  2. Report Service breaking point     (~5 phút)"
    info "  3. ETL pipeline E2E                  (~4 phút)"
    info "  4. Kafka throughput                  (~5 phút)"
    info "  Tổng: ~19 phút"
    echo ""

    log "[1/4] Ingest breaking point..."
    bash "${DIR}/01_ingest_breakpoint.sh"
    sleep 5

    log "[2/4] Report breaking point..."
    bash "${DIR}/02_report_breakpoint.sh"
    sleep 5

    log "[3/4] ETL pipeline E2E..."
    bash "${DIR}/03_etl_pipeline.sh"
    sleep 5

    log "[4/4] Kafka throughput..."
    bash "${DIR}/04_kafka_throughput.sh"
    ;;
  *)
    echo "Usage: bash run.sh [all|ingest|report|etl|kafka|rabbit]"
    exit 1
    ;;
esac

# ── Tổng kết ─────────────────────────────────────────────────
h1 "Hoàn thành"
log "Bắt đầu lúc : ${START_TIME}"
log "Kết thúc lúc: $(date '+%H:%M:%S')"
echo ""
log "Kết quả CSV trong các thư mục results/*/"
echo ""
echo "  Một số lệnh hữu ích sau test:"
echo "  ─────────────────────────────────────────────"
echo "  # Xem job bị failed"
echo "  curl ${ETL_URL}/jobs?status=FAILED"
echo ""
echo "  # Replay toàn bộ DLQ"
echo "  curl -X POST ${ETL_URL}/jobs/reprocess-dlq"
echo ""
echo "  # Xóa DLQ"
echo "  curl -X DELETE ${ETL_URL}/jobs/dlq"
echo ""
echo "  # Xem ETL metrics"
echo "  curl ${ETL_URL}/actuator/etl"
echo ""
echo "  # Flush Redis cache"
echo "  docker exec market-redis redis-cli -a ${REDIS_PASS} FLUSHDB"
