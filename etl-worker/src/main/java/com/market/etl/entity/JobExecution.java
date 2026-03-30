package com.market.etl.entity;

import jakarta.persistence.*;
import lombok.*;
import java.time.LocalDateTime;

@Data
@Entity
@Builder
@NoArgsConstructor
@AllArgsConstructor
@Table(name = "job_execution", catalog = "market_raw")
public class JobExecution {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "job_id", nullable = false, length = 36)
    private String jobId;

    @Column(name = "job_type", length = 50)
    private String jobType;

    @Column(name = "symbol", length = 10)
    private String symbol;

    @Column(name = "time_bucket")
    private LocalDateTime timeBucket;

    @Column(name = "status", length = 20)
    private String status; // RUNNING, SUCCESS, FAILED

    @Column(name = "retry_count")
    private Integer retryCount;

    @Column(name = "duration_ms")
    private Long durationMs;

    @Column(name = "error_msg", length = 500)
    private String errorMsg;

    @Column(name = "created_at")
    private LocalDateTime createdAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;
}
