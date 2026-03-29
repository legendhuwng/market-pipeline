package com.market.generator;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties
public class FakeGeneratorApplication {
    public static void main(String[] args) {
        SpringApplication.run(FakeGeneratorApplication.class, args);
    }
}
