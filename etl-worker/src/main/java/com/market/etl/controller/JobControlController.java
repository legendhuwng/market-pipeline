package com.market.etl.controller;

import com.market.etl.entity.JobExecution;
import com.market.etl.model.StagingJobMessage;
import com.market.etl.repository.JobExecutionRepository;
import com.market.etl.service.EtlMetrics;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageProperties;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.web.PageableDefault;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@Slf4j
@RestController
@RequestMapping("/jobs")
@RequiredArgsConstructor
public class JobControlController {

    private final JobExecutionRepository jobRepo;
    private final RabbitTemplate         rabbitTemplate;
    private final EtlMetrics             etlMetrics;

    // Xem tất cả job với filter theo status
    @GetMapping
    public ResponseEntity<Page<JobExecution>> getJobs(
            @RequestParam(required = false) String status,
            @PageableDefault(size = 20) Pageable pageable) {

        if (status != null) {
            return ResponseEntity.ok(
                jobRepo.findByStatusOrderByCreatedAtDesc(status, pageable));
        }
        return ResponseEntity.ok(
            jobRepo.findAll(pageable));
    }

    // Xem job cụ thể
    @GetMapping("/{jobId}")
    public ResponseEntity<JobExecution> getJob(@PathVariable String jobId) {
        return jobRepo.findByJobId(jobId)
            .map(ResponseEntity::ok)
            .orElse(ResponseEntity.notFound().build());
    }

    // Thống kê tổng quan
    @GetMapping("/stats")
    public ResponseEntity<Map<String, Object>> stats() {
        return ResponseEntity.ok(Map.of(
            "total",        jobRepo.count(),
            "success",      jobRepo.countByStatus("SUCCESS"),
            "failed",       jobRepo.countByStatus("FAILED"),
            "running",      jobRepo.countByStatus("RUNNING"),
            "successRate",  String.format("%.2f%%", etlMetrics.getSuccessRate()),
            "avgDurationMs",String.format("%.2fms", etlMetrics.getAvgDurationMs()),
            "dlqMessages",  getDlqCount()
        ));
    }

    // Reprocess tất cả message trong DLQ
    @PostMapping("/reprocess-dlq")
    public ResponseEntity<Map<String, Object>> reprocessDlq() {
        int count = 0;
        while (true) {
            Message message = rabbitTemplate.receive("etl.staging.dlq", 1000);
            if (message == null) break;

            // Reset retry count về 0 khi reprocess
            message.getMessageProperties().getHeaders().put("x-retry-count", 0);
            rabbitTemplate.send("etl.staging", message);
            count++;
        }

        log.info("[JobControl] Reprocessed {} messages from DLQ", count);
        return ResponseEntity.ok(Map.of(
            "reprocessed", count,
            "message", count > 0
                ? "Đã push " + count + " job từ DLQ vào etl.staging"
                : "DLQ đang rỗng"
        ));
    }

    // Reprocess 1 job cụ thể theo jobId
    @PostMapping("/reprocess/{jobId}")
    public ResponseEntity<Map<String, Object>> reprocessOne(@PathVariable String jobId) {
        var found = jobRepo.findByJobId(jobId);
        if (found.isEmpty()) return ResponseEntity.notFound().build();

        var job = found.get();
        StagingJobMessage msg = new StagingJobMessage();
        msg.setJobId(job.getJobId());
        msg.setType(job.getJobType());
        msg.setSymbol(job.getSymbol());
        msg.setTimeBucket(job.getTimeBucket().toString());

        rabbitTemplate.convertAndSend("etl.staging", msg, m -> {
            m.getMessageProperties().getHeaders().put("x-retry-count", 0);
            return m;
        });

        log.info("[JobControl] Reprocess job={}", jobId);
        Map<String, Object> result = new java.util.HashMap<>();
        result.put("jobId", jobId);
        result.put("message", "Job đã được push lại vào etl.staging");
        return ResponseEntity.ok(result);
    }

    // Xóa sạch DLQ
    @DeleteMapping("/dlq")
    public ResponseEntity<Map<String, Object>> clearDlq() {
        int count = 0;
        while (rabbitTemplate.receive("etl.staging.dlq", 500) != null) count++;
        log.info("[JobControl] Cleared {} messages from DLQ", count);
        return ResponseEntity.ok(Map.of("cleared", count));
    }

    private long getDlqCount() {
        try {
            org.springframework.amqp.core.QueueInformation info =
                rabbitTemplate.execute(ch -> {
                    com.rabbitmq.client.AMQP.Queue.DeclareOk ok =
                        ch.queueDeclarePassive("etl.staging.dlq");
                    return new org.springframework.amqp.core.QueueInformation(
                        "etl.staging.dlq", ok.getMessageCount(), ok.getConsumerCount());
                });
            return info != null ? info.getMessageCount() : 0;
        } catch (Exception e) {
            return -1;
        }
    }
}
