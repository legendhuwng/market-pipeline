package com.market.etl.service;

import com.market.etl.entity.*;
import com.market.etl.model.StagingJobMessage;
import com.market.etl.repository.*;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.Comparator;
import java.util.List;

@Slf4j
@Service
@RequiredArgsConstructor
public class EtlService {

    private final RawTradeRepository     rawTradeRepo;
    private final StgTrade1mRepository   stgRepo;
    private final DimTimeRepository      dimTimeRepo;
    private final FactMarket1mRepository factRepo;

    /**
     * 1 job = 1 transaction
     * Stage 1: RAW → STAGING
     * Stage 2: STAGING → FACT
     */
    @Transactional
    public void process(StagingJobMessage job) {
        log.info("[ETL] Start job={} symbol={} bucket={}",
            job.getJobId(), job.getSymbol(), job.getTimeBucket());

        LocalDateTime bucket = LocalDateTime.parse(job.getTimeBucket());
        LocalDateTime bucketEnd = bucket.plusMinutes(1);

        // ── Stage 1: RAW → STAGING ─────────────────────────────
        List<RawTrade> raws = rawTradeRepo.findBySymbolAndMinute(
            job.getSymbol(), bucket, bucketEnd);

        if (raws.isEmpty()) {
            log.warn("[ETL] No raw data for symbol={} bucket={}", job.getSymbol(), bucket);
            return;
        }

        // Aggregate
        BigDecimal open  = raws.get(0).getPrice();
        BigDecimal close = raws.get(raws.size() - 1).getPrice();
        BigDecimal high  = raws.stream().map(RawTrade::getPrice).max(Comparator.naturalOrder()).orElse(open);
        BigDecimal low   = raws.stream().map(RawTrade::getPrice).min(Comparator.naturalOrder()).orElse(open);
        long totalVolume = raws.stream().mapToLong(RawTrade::getVolume).sum();

        // Upsert staging
        StgTrade1m stg = stgRepo.findBySymbolAndTimeBucket(job.getSymbol(), bucket)
            .orElse(StgTrade1m.builder()
                .symbol(job.getSymbol())
                .timeBucket(bucket)
                .build());

        stg.setOpenPrice(open);
        stg.setClosePrice(close);
        stg.setHighPrice(high);
        stg.setLowPrice(low);
        stg.setTotalVolume(totalVolume);
        stg.setEventCount(raws.size());
        stgRepo.save(stg);

        log.debug("[ETL] Stage1 done: symbol={} count={} vol={}", job.getSymbol(), raws.size(), totalVolume);

        // ── Stage 2: STAGING → FACT ────────────────────────────
        // Upsert dim_time
        DimTime dimTime = dimTimeRepo.findByTs(bucket).orElseGet(() -> {
            DimTime d = DimTime.builder()
                .ts(bucket)
                .minuteOfHour(bucket.getMinute())
                .hourOfDay(bucket.getHour())
                .dayOfMonth(bucket.getDayOfMonth())
                .monthOfYear(bucket.getMonthValue())
                .year(bucket.getYear())
                .build();
            return dimTimeRepo.save(d);
        });

        // Skip nếu fact đã tồn tại
        if (factRepo.existsBySymbolAndTimeId(job.getSymbol(), dimTime.getTimeId())) {
            log.debug("[ETL] Fact already exists, skip: symbol={} timeId={}",
                job.getSymbol(), dimTime.getTimeId());
            return;
        }

        // Tính avg
        BigDecimal avgPrice = raws.stream()
            .map(RawTrade::getPrice)
            .reduce(BigDecimal.ZERO, BigDecimal::add)
            .divide(BigDecimal.valueOf(raws.size()), 4, RoundingMode.HALF_UP);

        FactMarket1m fact = FactMarket1m.builder()
            .symbol(job.getSymbol())
            .timeId(dimTime.getTimeId())
            .avgPrice(avgPrice)
            .maxPrice(high)
            .minPrice(low)
            .openPrice(open)
            .closePrice(close)
            .totalVolume(totalVolume)
            .tradeCount(raws.size())
            .createdAt(LocalDateTime.now())
            .build();

        factRepo.save(fact);

        log.info("[ETL] Done job={} symbol={} bucket={} tradeCount={} avgPrice={}",
            job.getJobId(), job.getSymbol(), bucket, raws.size(), avgPrice);
    }
}
