package com.market.etl.rabbitmq;

import com.market.etl.model.StagingJobMessage;
import com.market.etl.service.EtlService;
import com.market.etl.service.JobTrackingService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class StagingJobConsumer {

    private final EtlService         etlService;
    private final JobTrackingService trackingService;
    private final RabbitTemplate     rabbitTemplate;

    @Value("${etl.max-retries:3}")
    private int maxRetries;

    @RabbitListener(queues = "etl.staging")
    public void onStagingJob(StagingJobMessage job, Message message) {
        Integer retryCount = (Integer) message.getMessageProperties()
            .getHeaders().getOrDefault("x-retry-count", 0);

        log.debug("[ETL Consumer] job={} symbol={} retry={}",
            job.getJobId(), job.getSymbol(), retryCount);

        // Track RUNNING
        trackingService.markRunning(job, retryCount);

        try {
            long duration = etlService.process(job);
            // Track SUCCESS với duration thực tế
            trackingService.markSuccess(job.getJobId(), duration);

        } catch (Exception e) {
            log.warn("[ETL Consumer] FAILED job={} retry={}/{} err={}",
                job.getJobId(), retryCount, maxRetries, e.getMessage());

            if (retryCount < maxRetries) {
                // Push vào retry queue, tăng retry count
                log.info("[ETL Consumer] → retry queue attempt {}", retryCount + 1);
                rabbitTemplate.convertAndSend("etl.staging.retry", job, msg -> {
                    msg.getMessageProperties().getHeaders()
                        .put("x-retry-count", retryCount + 1);
                    return msg;
                });
            } else {
                // Hết retry → FAILED → DLQ
                log.error("[ETL Consumer] → DLQ job={}", job.getJobId());
                trackingService.markFailed(job.getJobId(), e.getMessage());
                throw new RuntimeException("Max retries exceeded", e);
            }
        }
    }
}
