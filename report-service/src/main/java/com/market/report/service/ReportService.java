package com.market.report.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.market.report.cache.CacheService;
import com.market.report.dto.StockResponse;
import com.market.report.entity.DimTime;
import com.market.report.entity.FactMarket1m;
import com.market.report.repository.DimTimeRepository;
import com.market.report.repository.FactMarketRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.event.ContextRefreshedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.*;
import java.util.stream.Collectors;

@Slf4j
@Service
@RequiredArgsConstructor
public class ReportService {

    private final FactMarketRepository factRepo;
    private final DimTimeRepository    dimTimeRepo;
    private final CacheService         cacheService;
    private final ObjectMapper         redisObjectMapper;

    public Page<StockResponse> getStocks(
            String symbol,
            LocalDateTime from,
            LocalDateTime to,
            BigDecimal minPrice,
            BigDecimal maxPrice,
            Pageable pageable) {

        // Cache chỉ áp dụng khi query đơn giản: chỉ filter theo symbol, page 0
        boolean simpleQuery = from == null && to == null
            && minPrice == null && maxPrice == null
            && pageable.getPageNumber() == 0 && symbol != null;

        if (simpleQuery) {
            String key = cacheService.buildKey(symbol);
            Optional<Object> cached = cacheService.get(key);
            if (cached.isPresent()) {
                try {
                    // Deserialize từ cache
                    List<?> list = redisObjectMapper.convertValue(cached.get(), List.class);
                    List<StockResponse> responses = list.stream()
                        .map(o -> redisObjectMapper.convertValue(o, StockResponse.class))
                        .toList();
                    return new PageImpl<>(responses, pageable, responses.size());
                } catch (Exception e) {
                    log.warn("[Report] Cache deserialize failed, fallback to DB: {}", e.getMessage());
                }
            }
        }

        // Query DB
        Long fromId = null, toId = null;
        if (from != null) fromId = dimTimeRepo.findFirstFrom(from).map(DimTime::getTimeId).orElse(null);
        if (to   != null) toId   = dimTimeRepo.findLastBefore(to).map(DimTime::getTimeId).orElse(null);

        Page<FactMarket1m> page = factRepo.findWithFilter(symbol, fromId, toId, minPrice, maxPrice, pageable);

        List<Long> timeIds = page.getContent().stream().map(FactMarket1m::getTimeId).toList();
        Map<Long, LocalDateTime> timeMap = dimTimeRepo.findAllById(timeIds).stream()
            .collect(Collectors.toMap(DimTime::getTimeId, DimTime::getTs));

        Page<StockResponse> result = page.map(f -> StockResponse.builder()
            .id(f.getId())
            .symbol(f.getSymbol())
            .timestamp(timeMap.get(f.getTimeId()))
            .avgPrice(f.getAvgPrice())
            .maxPrice(f.getMaxPrice())
            .minPrice(f.getMinPrice())
            .openPrice(f.getOpenPrice())
            .closePrice(f.getClosePrice())
            .totalVolume(f.getTotalVolume())
            .tradeCount(f.getTradeCount())
            .build());

        // Lưu vào cache nếu simple query
        if (simpleQuery) {
            cacheService.put(cacheService.buildKey(symbol), result.getContent());
        }

        return result;
    }

    public List<String> getSymbols() {
        return factRepo.findAllSymbols();
    }

    // Preload cache khi app khởi động
    @EventListener(ContextRefreshedEvent.class)
    public void preloadCache() {
        log.info("[Cache] Preloading hot symbols...");
        List<String> symbols = factRepo.findAllSymbols();
        for (String sym : symbols) {
            try {
                String key = cacheService.buildKey(sym);
                Page<FactMarket1m> page = factRepo.findWithFilter(
                    sym, null, null, null, null,
                    Pageable.ofSize(20)
                );
                List<Long> timeIds = page.getContent().stream().map(FactMarket1m::getTimeId).toList();
                Map<Long, LocalDateTime> timeMap = dimTimeRepo.findAllById(timeIds).stream()
                    .collect(Collectors.toMap(DimTime::getTimeId, DimTime::getTs));

                List<StockResponse> responses = page.getContent().stream()
                    .map(f -> StockResponse.builder()
                        .id(f.getId()).symbol(f.getSymbol())
                        .timestamp(timeMap.get(f.getTimeId()))
                        .avgPrice(f.getAvgPrice()).maxPrice(f.getMaxPrice())
                        .minPrice(f.getMinPrice()).openPrice(f.getOpenPrice())
                        .closePrice(f.getClosePrice()).totalVolume(f.getTotalVolume())
                        .tradeCount(f.getTradeCount()).build())
                    .toList();

                cacheService.put(key, responses);
                log.info("[Cache] Preloaded symbol={} count={}", sym, responses.size());
            } catch (Exception e) {
                log.warn("[Cache] Preload failed for {}: {}", sym, e.getMessage());
            }
        }
        log.info("[Cache] Preload done for {} symbols", symbols.size());
    }
}
