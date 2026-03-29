package com.market.generator.model;

import lombok.Builder;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
@Builder
public class TradeEvent {
    private String  eventId;
    private String  symbol;
    private BigDecimal price;
    private Long    volume;
    private LocalDateTime eventTime;
}
