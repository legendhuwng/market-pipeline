package com.market.report.dto;

import lombok.Builder;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
@Builder
public class StockResponse {
    private Long id;
    private String symbol;
    private LocalDateTime timestamp;
    private BigDecimal avgPrice;
    private BigDecimal maxPrice;
    private BigDecimal minPrice;
    private BigDecimal openPrice;
    private BigDecimal closePrice;
    private Long totalVolume;
    private Integer tradeCount;
}
