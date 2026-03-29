package com.market.generator.config;

import com.market.generator.service.FakeGeneratorService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class AppRunner implements ApplicationRunner {

    private final FakeGeneratorService generatorService;

    @Override
    public void run(ApplicationArguments args) {
        Thread thread = new Thread(generatorService, "generator-thread");
        thread.setDaemon(true);
        thread.start();
        log.info("[Generator] Background thread started");
    }
}
