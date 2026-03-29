package com.market.generator.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;
import java.util.Arrays;
import java.util.List;

@Data
@Configuration
@ConfigurationProperties(prefix = "generator")
public class GeneratorConfig {
    private String  ingestUrl   = "http://localhost:8080/api/trades";
    private long    intervalMs  = 500;
    private boolean enabled     = true;
}
