package com.market.generator.controller;

import com.market.generator.service.FakeGeneratorService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/generator")
@RequiredArgsConstructor
public class GeneratorController {

    private final FakeGeneratorService service;

    // Xem trạng thái
    @GetMapping("/status")
    public ResponseEntity<Map<String, Object>> status() {
        return ResponseEntity.ok(Map.of(
            "running",   service.isRunning(),
            "sentCount", service.getSentCount()
        ));
    }

    // Bật
    @PostMapping("/start")
    public ResponseEntity<String> start() {
        service.start();
        return ResponseEntity.ok("Generator started");
    }

    // Tắt
    @PostMapping("/stop")
    public ResponseEntity<String> stop() {
        service.stop();
        return ResponseEntity.ok("Generator stopped");
    }

    // Thay đổi tốc độ: POST /generator/speed?ms=200
    @PostMapping("/speed")
    public ResponseEntity<String> speed(@RequestParam long ms) {
        if (ms < 1 || ms > 10000) {
            return ResponseEntity.badRequest().body("ms phải từ 1 đến 10000");
        }
        service.setIntervalMs(ms);
        return ResponseEntity.ok("Interval set to " + ms + "ms");
    }
}
