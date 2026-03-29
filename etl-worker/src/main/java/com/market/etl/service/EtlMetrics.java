package com.market.etl.service;

import lombok.Getter;
import org.springframework.stereotype.Component;

import java.util.concurrent.atomic.AtomicLong;

@Getter
@Component
public class EtlMetrics {

    private final AtomicLong totalJobs     = new AtomicLong(0);
    private final AtomicLong successJobs   = new AtomicLong(0);
    private final AtomicLong failedJobs    = new AtomicLong(0);
    private final AtomicLong totalDuration = new AtomicLong(0); // ms

    public void recordSuccess(long durationMs) {
        totalJobs.incrementAndGet();
        successJobs.incrementAndGet();
        totalDuration.addAndGet(durationMs);
    }

    public void recordFailure() {
        totalJobs.incrementAndGet();
        failedJobs.incrementAndGet();
    }

    public double getSuccessRate() {
        long total = totalJobs.get();
        return total == 0 ? 0.0 :
            (double) successJobs.get() / total * 100.0;
    }

    public double getAvgDurationMs() {
        long success = successJobs.get();
        return success == 0 ? 0.0 :
            (double) totalDuration.get() / success;
    }
}
