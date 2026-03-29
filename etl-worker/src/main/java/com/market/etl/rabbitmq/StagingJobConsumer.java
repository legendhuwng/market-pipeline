package com.market.etl.rabbitmq;

import com.market.etl.model.StagingJobMessage;
import com.market.etl.service.EtlService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class StagingJobConsumer {

    private final EtlService etlService;

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
                return; // thành công → thoát
            } catch (Exception e) {
                lastException = e;
                log.warn("[ETL Consumer] Attempt {}/{} FAILED job={} err={}",
                    attempt, maxRetries, job.getJobId(), e.getMessage());
                if (attempt < maxRetries) {
                    try {
                        Thread.sleep(retryDelayMs * attempt); // backoff tuyến tính
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
        }

        // Hết retry → ném exception để RabbitMQ đẩy vào DLQ
        log.error("[ETL Consumer] Job FAILED after {} retries, sending to DLQ. job={}",
            maxRetries, job.getJobId());
        throw new RuntimeException("ETL failed after retries: " + job.getJobId(), lastException);
    }
}
