package com.market.etl.entity;

import jakarta.persistence.*;
import lombok.*;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
@Entity
@Builder
@NoArgsConstructor
@AllArgsConstructor
@Table(name = "market_dw.fact_market_1m")
public class FactMarket1m {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "symbol")
    private String symbol;

    @Column(name = "time_id")
    private Long timeId;

    @Column(name = "avg_price")
    private BigDecimal avgPrice;

    @Column(name = "max_price")
    private BigDecimal maxPrice;

    @Column(name = "min_price")
    private BigDecimal minPrice;

    @Column(name = "open_price")
    private BigDecimal openPrice;

    @Column(name = "close_price")
    private BigDecimal closePrice;

    @Column(name = "total_volume")
    private Long totalVolume;

    @Column(name = "trade_count")
    private Integer tradeCount;

    @Column(name = "created_at")
    private LocalDateTime createdAt;
}
