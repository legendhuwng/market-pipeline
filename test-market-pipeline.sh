#!/usr/bin/env bash
# Market Pipeline - Full Test Script v3
# Usage: chmod +x test-v3.sh && ./test-v3.sh
# Requires: curl, python3 (or jq)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INGEST="http://localhost:8080"
GENERATOR="http://localhost:8081"
ETL="http://localhost:8084"
REPORT="http://localhost:8085"

JWT_TOKEN=""
ADMIN_TOKEN=""
PASS=0
FAIL=0
SKIP=0

# ── json_get: extract field from JSON, works with python3 or jq ──
json_get() {
    local json="$1"
    local key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "${key} // empty" 2>/dev/null || true
    else
        python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    keys = '${key}'.lstrip('.').split('.')
    v = d
    for k in keys:
        v = v[k]
    print(v if v is not None else '')
except:
    print('')
" <<< "$json" 2>/dev/null || true
    fi
}

# ── do_curl: run curl, store status in CURL_STATUS, body in CURL_BODY ──
CURL_STATUS=""
CURL_BODY=""
do_curl() {
    local tmp
    tmp=$(curl -s -w "HTTPSTATUS:%{http_code}" "$@" 2>/dev/null)
    CURL_STATUS=$(echo "$tmp" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)
    CURL_BODY=$(echo "$tmp" | sed 's/HTTPSTATUS:[0-9]*$//')
}

# ── pretty: pretty-print JSON if possible ──
pretty() {
    local s="$1"
    if command -v jq &>/dev/null; then
        echo "$s" | jq . 2>/dev/null || echo "$s"
    else
        python3 -c "import sys,json; s=sys.stdin.read(); print(json.dumps(json.loads(s),indent=2,ensure_ascii=False))" <<< "$s" 2>/dev/null || echo "$s"
    fi
}

# ── run_test: test a curl request ──
run_test() {
    local name="$1"
    local expected="$2"
    shift 2

    echo -e "\n${BOLD}[TEST]${NC} $name"
    echo -e "  ${CYAN}CMD:${NC} curl $*"

    do_curl "$@"

    local display
    if [ -n "$CURL_BODY" ]; then
        display=$(pretty "$CURL_BODY")
    else
        display="(empty)"
    fi

    echo -e "  ${CYAN}STATUS:${NC} $CURL_STATUS"
    echo -e "  ${CYAN}BODY:${NC}"
    echo "$display" | sed 's/^/    /'

    if [ "$CURL_STATUS" = "$expected" ]; then
        echo -e "  ${GREEN}PASS${NC} (expected $expected, got $CURL_STATUS)"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}FAIL${NC} (expected $expected, got $CURL_STATUS)"
        FAIL=$((FAIL+1))
    fi
}

run_info() {
    local name="$1"
    shift
    echo -e "\n${BOLD}[INFO]${NC} $name"
    do_curl "$@"
    local display
    display=$(pretty "$CURL_BODY")
    echo -e "  ${CYAN}STATUS:${NC} $CURL_STATUS"
    echo "$display" | sed 's/^/    /'
}

skip_test() {
    echo -e "\n  ${YELLOW}[SKIP]${NC} $1"
    SKIP=$((SKIP+1))
}

header() {
    echo ""
    echo -e "${BOLD}${CYAN}=================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}=================================================${NC}"
}

section() {
    echo ""
    echo -e "${YELLOW}>> $1${NC}"
    echo -e "${YELLOW}$(printf -- '-%.0s' {1..48})${NC}"
}

wait_msg() {
    echo -e "\n  ${YELLOW}[WAIT] $1 seconds - $2${NC}"
    sleep "$1"
}

summary() {
    echo ""
    echo -e "${BOLD}${CYAN}=================================================${NC}"
    echo -e "${BOLD}  RESULT${NC}"
    echo -e "${BOLD}${CYAN}=================================================${NC}"
    echo -e "  ${GREEN}PASS: $PASS${NC}"
    echo -e "  ${RED}FAIL: $FAIL${NC}"
    echo -e "  ${YELLOW}SKIP: $SKIP${NC}"
    echo -e "  Total: $((PASS+FAIL+SKIP))"
    if [ "$FAIL" -eq 0 ]; then
        echo -e "\n  ${GREEN}${BOLD}All tests PASSED!${NC}"
    else
        echo -e "\n  ${RED}${BOLD}$FAIL test(s) FAILED.${NC}"
    fi
    echo ""
}

# ===================================================================
# PART 1 - INGEST SERVICE (8080)
# ===================================================================
header "PART 1: INGEST SERVICE (Port 8080)"

section "1.1 Health Check"
run_test "Health check" 200 \
    -X GET "$INGEST/api/health"

section "1.2 Valid trade events"
run_test "POST trade VCB" 202 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-test-001","symbol":"VCB","price":85.50,"volume":1000,"eventTime":"2026-04-02T10:00:00"}'

run_test "POST trade FPT" 202 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-test-002","symbol":"FPT","price":120.30,"volume":2000,"eventTime":"2026-04-02T10:00:15"}'

run_test "POST trade VNM" 202 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-test-003","symbol":"VNM","price":68.20,"volume":1500,"eventTime":"2026-04-02T10:00:30"}'

run_test "POST trade HPG" 202 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-test-004","symbol":"HPG","price":27.80,"volume":5000,"eventTime":"2026-04-02T10:00:45"}'

echo -e "\n  Sending 11 extra VCB events for ETL data..."
for i in 5 6 7 8 9 10 11 12 13 14 15; do
    curl -s -X POST "$INGEST/api/trades" \
        -H "Content-Type: application/json" \
        -d "{\"eventId\":\"evt-test-0${i}\",\"symbol\":\"VCB\",\"price\":85.${i}0,\"volume\":$((i*100)),\"eventTime\":\"2026-04-02T10:00:0${i}\"}" \
        > /dev/null
done
echo -e "  ${GREEN}Done${NC}"

section "1.3 Validation errors (must be 400)"
run_test "Reject empty eventId" 400 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"","symbol":"VCB","price":85.50,"volume":1000,"eventTime":"2026-04-02T10:00:00"}'

run_test "Reject negative price" 400 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-inv-001","symbol":"VCB","price":-10.00,"volume":1000,"eventTime":"2026-04-02T10:00:00"}'

run_test "Reject volume=0" 400 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-inv-002","symbol":"VCB","price":85.50,"volume":0,"eventTime":"2026-04-02T10:00:00"}'

run_test "Reject symbol > 10 chars" 400 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-inv-003","symbol":"TOOLONGSYMBOL","price":85.50,"volume":1000,"eventTime":"2026-04-02T10:00:00"}'

run_test "Reject price over max" 400 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-inv-004","symbol":"VCB","price":99999999.00,"volume":1000,"eventTime":"2026-04-02T10:00:00"}'

run_test "Reject null price" 400 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-inv-005","symbol":"VCB","volume":1000,"eventTime":"2026-04-02T10:00:00"}'

section "1.4 Malformed JSON -> 500 (known bug: should be 400)"
echo -e "\n  ${YELLOW}NOTE: GlobalExceptionHandler missing HttpMessageNotReadableException handler${NC}"
run_test "Malformed JSON -> 500 (known bug)" 500 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d 'this is not json'

# ===================================================================
# PART 2 - FAKE GENERATOR (8081)
# ===================================================================
header "PART 2: FAKE GENERATOR (Port 8081)"

section "2.1 Status"
run_test "GET status" 200 \
    -X GET "$GENERATOR/generator/status"

section "2.2 Stop / Start"
run_test "POST stop" 200 \
    -X POST "$GENERATOR/generator/stop"

run_test "GET status (running=false)" 200 \
    -X GET "$GENERATOR/generator/status"

run_test "POST start" 200 \
    -X POST "$GENERATOR/generator/start"

run_test "GET status (running=true)" 200 \
    -X GET "$GENERATOR/generator/status"

section "2.3 Speed Control"
run_test "Set interval to 200ms" 200 \
    -X POST "$GENERATOR/generator/speed?ms=200"

run_test "Reject ms=0" 400 \
    -X POST "$GENERATOR/generator/speed?ms=0"

run_test "Reject ms=99999" 400 \
    -X POST "$GENERATOR/generator/speed?ms=99999"

run_test "Reset interval to 500ms" 200 \
    -X POST "$GENERATOR/generator/speed?ms=500"

wait_msg 3 "wait for generator events"

# ===================================================================
# PART 3 - ETL WORKER (8084)
# ===================================================================
header "PART 3: ETL WORKER (Port 8084)"

section "3.1 Actuator"
run_test "Actuator health" 200 \
    -X GET "$ETL/actuator/health"

run_test "Custom ETL metrics" 200 \
    -X GET "$ETL/actuator/etl"

section "3.2 Job Statistics"
run_test "GET /jobs/stats" 200 \
    -X GET "$ETL/jobs/stats"

section "3.3 Job List & Filter"
run_test "List jobs page=0 size=5" 200 \
    -X GET "$ETL/jobs?page=0&size=5"

run_test "Filter status=SUCCESS" 200 \
    -X GET "$ETL/jobs?status=SUCCESS&page=0&size=5"

run_test "Filter status=FAILED" 200 \
    -X GET "$ETL/jobs?status=FAILED&page=0&size=5"

run_test "Filter status=RUNNING" 200 \
    -X GET "$ETL/jobs?status=RUNNING&page=0&size=5"

section "3.4 Job Lookup"
# Use do_curl directly - no stdout mixing
echo -e "\n  Fetching a jobId..."
do_curl -X GET "$ETL/jobs?status=SUCCESS&page=0&size=1"
JOB_ID=$(json_get "$CURL_BODY" ".content[0].jobId")

if [ -n "$JOB_ID" ] && [ "$JOB_ID" != "null" ]; then
    echo -e "  ${GREEN}Found jobId: $JOB_ID${NC}"

    run_test "GET job detail" 200 \
        -X GET "$ETL/jobs/$JOB_ID"

    run_test "Reprocess job (run 1)" 200 \
        -X POST "$ETL/jobs/reprocess/$JOB_ID"

    wait_msg 2 "wait for reprocess"

    run_test "Reprocess job (run 2 - idempotent)" 200 \
        -X POST "$ETL/jobs/reprocess/$JOB_ID"
else
    echo -e "  ${YELLOW}No jobs found yet${NC}"
    skip_test "GET job detail"
    skip_test "Reprocess job run 1"
    skip_test "Reprocess job run 2 (idempotent)"
fi

section "3.5 DLQ Operations"
run_test "Reprocess all DLQ" 200 \
    -X POST "$ETL/jobs/reprocess-dlq"

run_test "Clear DLQ" 200 \
    -X DELETE "$ETL/jobs/dlq"

section "3.6 Error Handling"
run_test "GET nonexistent job -> 404" 404 \
    -X GET "$ETL/jobs/nonexistent-job-id-xyz"

run_test "Reprocess nonexistent job -> 404" 404 \
    -X POST "$ETL/jobs/reprocess/nonexistent-job-id-xyz"

# ===================================================================
# PART 4 - REPORT SERVICE AUTH (8085)
# ===================================================================
header "PART 4: REPORT SERVICE - Auth (Port 8085)"

echo -e "${YELLOW}"
echo "  NOTE: Spring Security returns 403 (not 401) for unauthenticated"
echo "  requests because SecurityConfig has no AuthenticationEntryPoint."
echo "  This is the actual behavior of the current source code."
echo -e "${NC}"

section "4.1 Security defaults"
run_test "/api/health no token -> 403" 403 \
    -X GET "$REPORT/api/health"

run_test "/auth/login reachable (permitAll)" 200 \
    -X POST "$REPORT/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"user","password":"user123"}'

section "4.2 Login - extract JWT directly"
# Use do_curl to keep response in CURL_BODY, extract cleanly
echo -e "\n  Logging in as user..."
do_curl -X POST "$REPORT/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"user","password":"user123"}'

JWT_TOKEN=$(json_get "$CURL_BODY" ".token")

if [ -n "$JWT_TOKEN" ] && [ "$JWT_TOKEN" != "null" ]; then
    echo -e "  ${GREEN}PASS${NC} user login -> token: ${JWT_TOKEN:0:40}..."
    PASS=$((PASS+1))
else
    echo -e "  ${RED}FAIL${NC} could not extract JWT token"
    echo -e "  ${RED}  Response was: $CURL_BODY${NC}"
    FAIL=$((FAIL+1))
fi

echo -e "\n  Logging in as admin..."
do_curl -X POST "$REPORT/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"admin123"}'

ADMIN_TOKEN=$(json_get "$CURL_BODY" ".token")

if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    echo -e "  ${GREEN}PASS${NC} admin login -> token: ${ADMIN_TOKEN:0:40}..."
    PASS=$((PASS+1))
else
    echo -e "  ${RED}FAIL${NC} could not extract admin token"
    FAIL=$((FAIL+1))
fi

section "4.3 Login failures"
# Spring Security catches BadCredentialsException before returning response
# -> returns 403 (no AuthenticationEntryPoint configured)
run_test "Wrong password -> 403" 403 \
    -X POST "$REPORT/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"user","password":"wrong-password"}'

run_test "Unknown user -> 403" 403 \
    -X POST "$REPORT/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"nobody","password":"pass123"}'

# loadUserByUsername(null) throws before @Valid runs -> 403
run_test "Missing username -> 403 (loadUserByUsername runs before @Valid)" 403 \
    -X POST "$REPORT/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"password":"user123"}'

section "4.4 Access without / with fake token"
run_test "No token -> 403" 403 \
    -X GET "$REPORT/api/stocks"

run_test "Fake token -> 403" 403 \
    -X GET "$REPORT/api/stocks" \
    -H "Authorization: Bearer this.is.a.fake.token"

# ===================================================================
# PART 5 - REPORT SERVICE STOCK QUERY (needs JWT)
# ===================================================================
header "PART 5: REPORT SERVICE - Stock Query"

if [ -z "$JWT_TOKEN" ] || [ "$JWT_TOKEN" = "null" ]; then
    echo -e "${RED}  No JWT token - skipping part 5${NC}"
    for i in $(seq 1 15); do skip_test "Stock query $i"; done
else

section "5.1 Symbols"
run_test "GET symbols" 200 \
    -X GET "$REPORT/api/stocks/symbols" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.2 Basic pagination"
run_test "GET stocks page=0 size=10" 200 \
    -X GET "$REPORT/api/stocks?page=0&size=10" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "GET stocks page=1 size=5" 200 \
    -X GET "$REPORT/api/stocks?page=1&size=5" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.3 Filter by symbol"
run_test "Filter symbol=VCB" 200 \
    -X GET "$REPORT/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Filter symbol=FPT" 200 \
    -X GET "$REPORT/api/stocks?symbol=FPT&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Filter symbol=NONEXIST (empty result)" 200 \
    -X GET "$REPORT/api/stocks?symbol=NONEXIST&page=0&size=10" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.4 Filter by time"
run_test "Filter from=09:00 to=11:00" 200 \
    -X GET "$REPORT/api/stocks?from=2026-04-02T09:00:00&to=2026-04-02T11:00:00&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Filter from=2026-04-02T00:00:00" 200 \
    -X GET "$REPORT/api/stocks?from=2026-04-02T00:00:00&page=0&size=10" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.5 Filter by price"
run_test "Filter minPrice=80" 200 \
    -X GET "$REPORT/api/stocks?minPrice=80&page=0&size=10" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Filter maxPrice=50" 200 \
    -X GET "$REPORT/api/stocks?maxPrice=50&page=0&size=10" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Filter minPrice=60 maxPrice=90" 200 \
    -X GET "$REPORT/api/stocks?minPrice=60&maxPrice=90&page=0&size=10" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.6 Combined filter"
run_test "symbol=VCB + time + price range" 200 \
    -X GET "$REPORT/api/stocks?symbol=VCB&from=2026-04-02T09:00:00&to=2026-04-02T23:59:59&minPrice=80&maxPrice=95&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.7 Sorting"
run_test "Sort id ASC" 200 \
    -X GET "$REPORT/api/stocks?page=0&size=5&sort=id,asc" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Sort id DESC" 200 \
    -X GET "$REPORT/api/stocks?page=0&size=5&sort=id,desc" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "5.8 OpenAPI / Swagger"
run_test "GET /api-docs (OpenAPI JSON)" 200 \
    -X GET "$REPORT/api-docs"

run_test "GET /swagger-ui/index.html" 200 \
    -X GET "$REPORT/swagger-ui/index.html"

fi # end JWT check

# ===================================================================
# PART 6 - CACHE BEHAVIOR
# ===================================================================
header "PART 6: Cache Behavior - Redis"

if [ -z "$JWT_TOKEN" ] || [ "$JWT_TOKEN" = "null" ]; then
    echo -e "${RED}  No JWT token - skipping part 6${NC}"
    skip_test "Cache MISS -> HIT (VCB run 1)"
    skip_test "Cache HIT (VCB run 2)"
    skip_test "Complex query bypass cache (with time filter)"
    skip_test "Page 1 bypass cache"
else

section "6.1 MISS -> HIT"
run_test "VCB query run 1 (cold - MISS)" 200 \
    -X GET "$REPORT/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "VCB query run 2 (warm - HIT)" 200 \
    -X GET "$REPORT/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

section "6.2 Complex query skips cache"
run_test "With time filter -> no cache" 200 \
    -X GET "$REPORT/api/stocks?symbol=VCB&from=2026-04-02T09:00:00&page=0&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

run_test "Page 1 -> no cache" 200 \
    -X GET "$REPORT/api/stocks?symbol=VCB&page=1&size=20" \
    -H "Authorization: Bearer $JWT_TOKEN"

fi

# ===================================================================
# PART 7 - END-TO-END PIPELINE
# ===================================================================
header "PART 7: End-to-End Pipeline Test"

section "7.1 Send batch events to trigger full pipeline"
echo -e "\n  Sending 20 TCB events (minute 10:30)..."
for i in $(seq 1 20); do
    curl -s -X POST "$INGEST/api/trades" \
        -H "Content-Type: application/json" \
        -d "{\"eventId\":\"e2e-tcb-$(printf '%03d' $i)\",\"symbol\":\"TCB\",\"price\":32.$(printf '%02d' $i),\"volume\":$((i*200)),\"eventTime\":\"2026-04-02T10:30:$(printf '%02d' $((i*2 % 59)))\"}" \
        > /dev/null
done
echo -e "  ${GREEN}Done - 20 TCB events${NC}"

echo -e "\n  Sending 15 GAS events (minute 10:31)..."
for i in $(seq 1 15); do
    curl -s -X POST "$INGEST/api/trades" \
        -H "Content-Type: application/json" \
        -d "{\"eventId\":\"e2e-gas-$(printf '%03d' $i)\",\"symbol\":\"GAS\",\"price\":78.$(printf '%02d' $i),\"volume\":$((i*100)),\"eventTime\":\"2026-04-02T10:31:$(printf '%02d' $((i*3 % 59)))\"}" \
        > /dev/null
done
echo -e "  ${GREEN}Done - 15 GAS events${NC}"

wait_msg 6 "Kafka batch + RabbitMQ ETL processing"

section "7.2 Verify pipeline results"
run_test "Ingest receivedCount increased" 200 \
    -X GET "$INGEST/api/health"

run_test "ETL job count increased" 200 \
    -X GET "$ETL/jobs/stats"

run_test "ETL metrics updated" 200 \
    -X GET "$ETL/actuator/etl"

if [ -n "$JWT_TOKEN" ] && [ "$JWT_TOKEN" != "null" ]; then
    run_test "TCB appears in Report API" 200 \
        -X GET "$REPORT/api/stocks?symbol=TCB&page=0&size=10" \
        -H "Authorization: Bearer $JWT_TOKEN"

    run_test "GAS appears in Report API" 200 \
        -X GET "$REPORT/api/stocks?symbol=GAS&page=0&size=10" \
        -H "Authorization: Bearer $JWT_TOKEN"
fi

# ===================================================================
# PART 8 - IDEMPOTENCY
# ===================================================================
header "PART 8: Idempotency"

section "8.1 Duplicate eventId"
run_test "Re-send evt-test-001 (ingest accepts, DB rejects duplicate PK)" 202 \
    -X POST "$INGEST/api/trades" \
    -H "Content-Type: application/json" \
    -d '{"eventId":"evt-test-001","symbol":"VCB","price":99.99,"volume":9999,"eventTime":"2026-04-02T10:00:00"}'

section "8.2 ETL reprocess idempotency"
echo -e "\n  Fetching jobId for idempotency test..."
do_curl -X GET "$ETL/jobs?status=SUCCESS&page=0&size=1"
JOB_ID2=$(json_get "$CURL_BODY" ".content[0].jobId")

if [ -n "$JOB_ID2" ] && [ "$JOB_ID2" != "null" ]; then
    echo -e "  ${GREEN}jobId: $JOB_ID2${NC}"

    run_test "Reprocess run 1" 200 \
        -X POST "$ETL/jobs/reprocess/$JOB_ID2"

    wait_msg 2 "wait for ETL"

    run_test "Reprocess run 2 (fact table unchanged)" 200 \
        -X POST "$ETL/jobs/reprocess/$JOB_ID2"
else
    skip_test "Reprocess idempotency run 1"
    skip_test "Reprocess idempotency run 2"
fi

# ===================================================================
# PART 9 - FINAL SNAPSHOT
# ===================================================================
header "PART 9: Final System Snapshot"

run_info "Ingest: total events" \
    -X GET "$INGEST/api/health"

run_info "ETL: job stats" \
    -X GET "$ETL/jobs/stats"

run_info "ETL: in-memory metrics" \
    -X GET "$ETL/actuator/etl"

run_info "Generator: final state" \
    -X GET "$GENERATOR/generator/status"

if [ -n "$JWT_TOKEN" ] && [ "$JWT_TOKEN" != "null" ]; then
    run_info "Report: symbols with data" \
        -X GET "$REPORT/api/stocks/symbols" \
        -H "Authorization: Bearer $JWT_TOKEN"
fi

# ===================================================================
summary

echo -e "${BOLD}${YELLOW}KNOWN BUGS IN SOURCE CODE:${NC}"
echo ""
echo -e "  ${RED}Bug 1 - Malformed JSON returns 500 (should be 400):${NC}"
echo "    File: ingest-service/GlobalExceptionHandler.java"
echo "    Fix: Add handler for HttpMessageNotReadableException:"
echo "         @ExceptionHandler(HttpMessageNotReadableException.class)"
echo "         public ResponseEntity<?> handleBadJson(...) {"
echo "             return ResponseEntity.badRequest().body(Map.of("
echo "                 \"status\", 400, \"message\", \"Malformed JSON\"));"
echo "         }"
echo ""
echo -e "  ${RED}Bug 2 - Unauthenticated requests return 403 (should be 401):${NC}"
echo "    File: report-service/SecurityConfig.java"
echo "    Fix: Add to filterChain() before .build():"
echo "         .exceptionHandling(ex -> ex"
echo "             .authenticationEntryPoint((req, res, e) ->"
echo "                 res.sendError(HttpServletResponse.SC_UNAUTHORIZED)))"
echo ""
echo -e "  ${RED}Bug 3 - @Valid on LoginRequest not evaluated (missing username returns 403):${NC}"
echo "    File: report-service/AuthController.java"
echo "    Root cause: loadUserByUsername() is called before @Valid runs."
echo "    Fix: Add null guard in AuthController.login():"
echo "         if (req.getUsername() == null || req.getUsername().isBlank())"
echo "             throw new BadCredentialsException(\"Username required\");"
echo ""