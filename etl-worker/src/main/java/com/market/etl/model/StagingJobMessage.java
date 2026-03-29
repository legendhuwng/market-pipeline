package com.market.etl.model;

import lombok.Data;

@Data
public class StagingJobMessage {
    private String jobId;
    private String type;
    private String symbol;
    private String timeBucket;
}
