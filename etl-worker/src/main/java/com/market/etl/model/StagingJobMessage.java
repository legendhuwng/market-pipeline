package com.market.etl.model;

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
    private String type;
    private String symbol;
    private String timeBucket;
}
