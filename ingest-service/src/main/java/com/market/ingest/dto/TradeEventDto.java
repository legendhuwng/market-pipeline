package com.market.ingest.dto;

import jakarta.validation.constraints.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
public class TradeEventDto {

    @NotBlank(message = "eventId không được rỗng")
    private String eventId;

    @NotBlank(message = "symbol không được rỗng")
    @Size(max = 10, message = "symbol tối đa 10 ký tự")
    private String symbol;

    @NotNull(message = "price không được null")
    @Positive(message = "price phải > 0")
    @DecimalMax(value = "9999999.9999", message = "price quá lớn")
    private BigDecimal price;

    @NotNull(message = "volume không được null")
    @Positive(message = "volume phải > 0")
    private Long volume;

    @NotNull(message = "eventTime không được null")
    private String eventTime;
}
