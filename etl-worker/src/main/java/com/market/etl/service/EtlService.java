package com.market.etl.service;

import com.market.etl.entity.*;
import com.market.etl.model.StagingJobMessage;
import com.market.etl.rabbitmq.CacheInvalidationPublisher;
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

    private final RawTradeRepository         rawTradeRepo;
    private final StgTrade1mRepository       stgRepo;
    private final DimTimeRepository          dimTimeRepo;
    private final FactMarket1mRepository     factRepo;
    private final CacheInvalidationPublisher cachePublisher;
    private final EtlMetrics                 etlMetrics;

    @Transactional
    public void process(StagingJobMessage job) {
        long start = System.currentTimeMillis();
        log.info("[ETL] Start job={} symbol={} bucket={}",
            job.getJobId(), job.getSymbol(), job.getTimeBucket());

        try {
            doProcess(job);
            long duration = System.currentTimeMillis() - start;
            etlMetrics.recordSuccess(duration);
            log.info("[ETL] Done job={} symbol={} bucket={} duration={}ms",
                job.getJobId(), job.getSymbol(), job.getTimeBucket(), duration);
        } catch (Exception e) {
            etlMetrics.recordFailure();
            throw e;
        }
    }

    private void doProcess(StagingJobMessage job) {
        LocalDateTime bucket    = LocalDateTime.parse(job.getTimeBucket());
        LocalDateTime bucketEnd = bucket.plusMinutes(1);

        List<RawTrade> raws = rawTradeRepo.findBySymbolAndMinute(
            job.getSymbol(), bucket, bucketEnd);

        if (raws.isEmpty()) {
            log.warn("[ETL] No raw data symbol={} bucket={}", job.getSymbol(), bucket);
            return;
        }

        BigDecimal open  = raws.get(0).getPrice();
        BigDecimal close = raws.get(raws.size() - 1).getPrice();
        BigDecimal high  = raws.stream().map(RawTrade::getPrice).max(Comparator.naturalOrder()).orElse(open);
        BigDecimal low   = raws.stream().map(RawTrade::getPrice).min(Comparator.naturalOrder()).orElse(open);
        long totalVolume = raws.stream().mapToLong(RawTrade::getVolume).sum();

        StgTrade1m stg = stgRepo.findBySymbolAndTimeBucket(job.getSymbol(), bucket)
            .orElse(StgTrade1m.builder().symbol(job.getSymbol()).timeBucket(bucket).build());

        stg.setOpenPrice(open);
        stg.setClosePrice(close);
        stg.setHighPrice(high);
        stg.setLowPrice(low);
        stg.setTotalVolume(totalVolume);
        stg.setEventCount(raws.size());
        stgRepo.save(stg);

        log.debug("[ETL] Stage1 done: symbol={} count={}", job.getSymbol(), raws.size());

        DimTime dimTime = dimTimeRepo.findByTs(bucket).orElseGet(() ->
            dimTimeRepo.save(DimTime.builder()
                .ts(bucket)
                .minuteOfHour(bucket.getMinute())
                .hourOfDay(bucket.getHour())
                .dayOfMonth(bucket.getDayOfMonth())
                .monthOfYear(bucket.getMonthValue())
                .year(bucket.getYear())
                .build()));

        if (factRepo.existsBySymbolAndTimeId(job.getSymbol(), dimTime.getTimeId())) {
            log.debug("[ETL] Fact exists, skip symbol={}", job.getSymbol());
            return;
        }

        BigDecimal avgPrice = raws.stream()
            .map(RawTrade::getPrice)
            .reduce(BigDecimal.ZERO, BigDecimal::add)
            .divide(BigDecimal.valueOf(raws.size()), 4, RoundingMode.HALF_UP);

        factRepo.save(FactMarket1m.builder()
            .symbol(job.getSymbol())
            .timeId(dimTime.getTimeId())
            .avgPrice(avgPrice)
            .maxPrice(high).minPrice(low)
            .openPrice(open).closePrice(close)
            .totalVolume(totalVolume)
            .tradeCount(raws.size())
            .createdAt(LocalDateTime.now())
            .build());

        cachePublisher.invalidate(job.getSymbol());
    }
}
