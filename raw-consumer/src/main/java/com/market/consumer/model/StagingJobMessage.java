package com.market.consumer.model;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class StagingJobMessage {
    private String jobId;
    private String type;      // "BUILD_STAGING_1M"
    private String symbol;
    private String timeBucket; // "2026-03-29T14:45:00"
}
