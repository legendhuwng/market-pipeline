package com.market.consumer.model;

import lombok.Data;
import java.math.BigDecimal;

@Data
public class TradeEventMessage {
    private String eventId;
    private String symbol;
    private BigDecimal price;
    private Long volume;
    private String eventTime;
}
