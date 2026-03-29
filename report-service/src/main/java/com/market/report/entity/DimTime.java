package com.market.report.entity;

import jakarta.persistence.*;
import lombok.Data;
import java.time.LocalDateTime;

@Data
@Entity
@Table(name = "dim_time", catalog = "market_dw")
public class DimTime {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long timeId;

    @Column(name = "ts")
    private LocalDateTime ts;

    @Column(name = "minute_of_hour")
    private Integer minuteOfHour;

    @Column(name = "hour_of_day")
    private Integer hourOfDay;

    @Column(name = "day_of_month")
    private Integer dayOfMonth;

    @Column(name = "month_of_year")
    private Integer monthOfYear;

    @Column(name = "year")
    private Integer year;
}
