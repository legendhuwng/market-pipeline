package com.market.report.controller;

import com.market.report.dto.StockResponse;
import com.market.report.service.ReportService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.web.PageableDefault;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api")
@RequiredArgsConstructor
@Tag(name = "Stocks", description = "Market data API")
@SecurityRequirement(name = "bearerAuth")
public class StockController {

    private final ReportService reportService;

    @GetMapping("/stocks")
    @Operation(summary = "Lấy dữ liệu thị trường với filter và pagination")
    public ResponseEntity<Page<StockResponse>> getStocks(
            @Parameter(description = "Mã cổ phiếu, vd: VCB")
            @RequestParam(required = false) String symbol,

            @Parameter(description = "Từ thời điểm, vd: 2026-03-29T17:00:00")
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) LocalDateTime from,

            @Parameter(description = "Đến thời điểm")
            @RequestParam(required = false)
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) LocalDateTime to,

            @RequestParam(required = false) BigDecimal minPrice,
            @RequestParam(required = false) BigDecimal maxPrice,

            @PageableDefault(size = 20, sort = "id") Pageable pageable) {

        return ResponseEntity.ok(
            reportService.getStocks(symbol, from, to, minPrice, maxPrice, pageable));
    }

    @GetMapping("/stocks/symbols")
    @Operation(summary = "Lấy danh sách symbol có trong hệ thống")
    public ResponseEntity<List<String>> getSymbols() {
        return ResponseEntity.ok(reportService.getSymbols());
    }

    @GetMapping("/health")
    @Operation(summary = "Health check")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP", "service", "report-service"));
    }
}
