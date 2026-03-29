package com.market.etl.rabbitmq;

import com.market.etl.model.StagingJobMessage;
import com.market.etl.service.EtlService;
import com.market.etl.service.EtlMetrics;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class StagingJobConsumer {

    private final EtlService  etlService;
    private final EtlMetrics  etlMetrics;

    @Value("${etl.max-retries:3}")
    private int maxRetries;

    @Value("${etl.retry-delay-ms:5000}")
    private long retryDelayMs;

    @RabbitListener(queues = "etl.staging")
    public void onStagingJob(StagingJobMessage job) {
        log.debug("[ETL Consumer] Received job={} symbol={}", job.getJobId(), job.getSymbol());

        Exception lastException = null;
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                etlService.process(job);
                return;
            } catch (Exception e) {
                lastException = e;
                log.warn("[ETL Consumer] Attempt {}/{} FAILED job={} err={}",
                    attempt, maxRetries, job.getJobId(), e.getMessage());
                if (attempt < maxRetries) {
                    try { Thread.sleep(retryDelayMs * attempt); }
                    catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
                }
            }
        }

        log.error("[ETL Consumer] Job FAILED after {} retries → DLQ job={}",
            maxRetries, job.getJobId());
        throw new RuntimeException("ETL failed: " + job.getJobId(), lastException);
    }
}
