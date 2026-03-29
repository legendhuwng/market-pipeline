package com.market.etl.actuator;

import com.market.etl.service.EtlMetrics;
import lombok.RequiredArgsConstructor;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

import java.util.Map;

@Component
@Endpoint(id = "etl")
@RequiredArgsConstructor
public class EtlMetricsEndpoint {

    private final EtlMetrics etlMetrics;

    @ReadOperation
    public Map<String, Object> metrics() {
        return Map.of(
            "totalJobs",      etlMetrics.getTotalJobs().get(),
            "successJobs",    etlMetrics.getSuccessJobs().get(),
            "failedJobs",     etlMetrics.getFailedJobs().get(),
            "successRate",    String.format("%.2f%%", etlMetrics.getSuccessRate()),
            "avgDurationMs",  String.format("%.2fms", etlMetrics.getAvgDurationMs())
        );
    }
}
