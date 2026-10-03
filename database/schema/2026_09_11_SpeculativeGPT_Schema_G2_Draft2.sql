-- =====================================================================
-- SpeculativeGPT — Database Schema Group 2
-- Instruments, market observations, and bot output records (A, B, C)
--
-- Draft G2-D2 | 2026-09-11 | PROPOSED — NOT APPLIED
-- Supersedes G2-D1 (approved baseline 2026-09-11). Only change: the
-- instrument_observation.data_source default is 'ibkr', matching G2-D6.
--
-- Depends on: Group 1 Draft 3
--
-- Owner decisions reflected in this draft:
--   G1-D2 approved as baseline.
--   Strategy vs Platform labeling confirmed.
--   Forced-upgrade exception confirmed.
--   Manual Risk Multiplier bounds 0.25–2.00 confirmed.
--
-- Design decisions in this draft:
--   G2-D1  Market observations captured once per slot and shared across
--          tracks so primary and candidate judge identical data.
--   G2-D2  Instrument table uses is_active flag; adding or pausing an
--          instrument is one row change (but is a strategy revision).
--   G2-D3  Bot output tables are write-once: inserts only while the
--          owning run is in 'running' status. No updates, no deletes.
--   G2-D4  Bot C writes a decision row for every instrument at every
--          trading window, whether proposal or pass, so the audit trail
--          has no gaps.
--   G2-D5  Proposal legs and exit plans stored as JSONB within
--          bot_c_decision; headline numbers in explicit columns for
--          dashboard queries.
--
-- Target: Supabase Postgres 15+.
-- Conventions: see Group 1 header (sgpt schema, RLS, timestamptz,
--   text + CHECK, append-only audit rows, no TRUNCATE grant).
-- =====================================================================

-- =====================================================================
-- GUARD FUNCTIONS (shared across multiple tables)
-- =====================================================================

-- Observation tables (shared market data): write-once, no updates,
-- no deletes. Not tied to any single run's status because the data
-- is valid regardless of what happened to the capturing run.
create function sgpt.observation_guard() returns trigger
language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        raise exception '% rows are permanent audit records and cannot be deleted',
            tg_table_name;
    end if;
    if tg_op = 'UPDATE' then
        raise exception '% rows are write-once and cannot be updated',
            tg_table_name;
    end if;
    return new;
end;
$$;

-- Bot output tables: insert only while the owning window_run is
-- 'running'. No updates, no deletes. This is the same zombie-write
-- protection as Group 1's step guard, applied to bot outputs.
create function sgpt.bot_output_guard() returns trigger
language plpgsql as $$
declare v_run_status text;
begin
    if tg_op = 'DELETE' then
        raise exception '% rows are permanent audit records and cannot be deleted',
            tg_table_name;
    end if;
    if tg_op = 'UPDATE' then
        raise exception '% rows are write-once and cannot be updated',
            tg_table_name;
    end if;

    -- INSERT: verify the owning run is still running.
    select status into v_run_status
      from sgpt.window_run
     where window_run_id = new.window_run_id;

    if v_run_status is distinct from 'running' then
        raise exception 'cannot write to % for run %: run status is %, not running',
            tg_table_name, new.window_run_id,
            coalesce(v_run_status, 'unknown (run not found)');
    end if;

    return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. instrument
--    The monitored instrument universe. Exactly thirteen at launch;
--    the table supports growth. Adding or removing an instrument is a
--    one-row change but constitutes a strategy revision per the
--    revision model (Section 10.1 of Requirements v1.2).
--
--    Commodity ETF tickers are seeded with the best-guess symbols from
--    v1.2. The is_confirmed flag tracks which have been verified for
--    liquidity. All must be confirmed before first paper trade.
-- ---------------------------------------------------------------------
create table sgpt.instrument (
    instrument_code     text primary key
                          check (instrument_code ~ '^[A-Z]{1,10}$'),
    display_name        text not null,
    asset_class         text not null
                          check (asset_class in ('equity', 'commodity_etf')),
    has_extended_options boolean not null default false,  -- options trade past 4:00 PM ET
    is_confirmed        boolean not null default true,    -- false = ticker pending final verification
    is_active           boolean not null default true,
    added_at            timestamptz not null default now(),
    deactivated_at      timestamptz,
    note                text,
    constraint instrument_active_chk check (is_active or deactivated_at is not null)
);

alter table sgpt.instrument enable row level security;

-- Seed: Mag 7 confirmed, commodity ETFs as best-guess pending verification.
insert into sgpt.instrument (instrument_code, display_name, asset_class, has_extended_options, is_confirmed) values
    ('AAPL',  'Apple',                  'equity',        false, true),
    ('MSFT',  'Microsoft',              'equity',        false, true),
    ('AMZN',  'Amazon',                 'equity',        false, true),
    ('GOOGL', 'Alphabet',               'equity',        false, true),
    ('META',  'Meta Platforms',          'equity',        false, true),
    ('NVDA',  'NVIDIA',                 'equity',        false, true),
    ('TSLA',  'Tesla',                  'equity',        false, true),
    ('USO',   'Oil ETF',                'commodity_etf', false, false),
    ('GLD',   'Gold ETF',               'commodity_etf', true,  false),
    ('SLV',   'Silver ETF',             'commodity_etf', true,  false),
    ('UNG',   'Natural Gas ETF',        'commodity_etf', true,  false),
    ('XME',   'Metals & Mining ETF',    'commodity_etf', true,  false),
    ('DJP',   'Broad Commodities ETF',  'commodity_etf', false, false);

-- ---------------------------------------------------------------------
-- 2. market_event
--    Upcoming events fetched from the external provider and persisted
--    for Bot A to read. Each row is one event as the provider reported
--    it. Bot A applies blackout rules (strategy-specific durations) and
--    records the resulting blackouts in bot_a_blackout.
--
--    Provider selection is still open. This table stores the minimal
--    fields any provider would supply. Additional provider-specific
--    fields go in the detail JSONB column.
-- ---------------------------------------------------------------------
create table sgpt.market_event (
    event_id         uuid primary key default gen_random_uuid(),
    event_type       text not null
                       check (event_type in (
                           'earnings', 'fomc', 'fed_speech',
                           'economic_data', 'ex_dividend', 'other')),
    instrument_code  text references sgpt.instrument (instrument_code),
        -- null for market-wide events like FOMC
    event_date       date not null,
    event_time_et    time,               -- null if all-day or unknown
    description      text not null,
    source           text not null,       -- provider name
    source_event_id  text,                -- provider's key, for dedup
    detail           jsonb,               -- provider-specific payload
    loaded_at        timestamptz not null default now(),
    superseded_at    timestamptz,         -- set when a corrected version arrives
    constraint market_event_source_uq unique nulls not distinct (source, source_event_id)
);

create index market_event_date_idx on sgpt.market_event (event_date)
    where superseded_at is null;
create index market_event_instrument_idx on sgpt.market_event (instrument_code, event_date)
    where superseded_at is null and instrument_code is not null;

alter table sgpt.market_event enable row level security;

-- ---------------------------------------------------------------------
-- 3. slot_observation
--    One row per (trade_date, slot_code). The wrapper for market data
--    captured at a trading window. Shared across all tracks: the first
--    track to run captures the observation; subsequent tracks in the
--    same slot read it without re-pulling.
--
--    VIX and other market-wide readings live here. Per-instrument
--    prices live in instrument_observation (child table).
-- ---------------------------------------------------------------------
create table sgpt.slot_observation (
    trade_date            date not null references sgpt.market_calendar (trade_date),
    slot_code             text not null,
    observed_at           timestamptz not null default now(),
    captured_by_run_id    uuid not null references sgpt.window_run (window_run_id),
        -- which run performed the capture, for traceability
    vix_level             numeric(7,2),         -- current VIX reading
    vix_prior_close       numeric(7,2),         -- previous session close
    market_breadth_note   text,                  -- optional breadth summary
    observation_note      text,
    primary key (trade_date, slot_code),
    constraint slot_obs_slot_fk foreign key (slot_code)
        references sgpt.schedule_slot (slot_code)
);

create trigger slot_observation_guard_trg
    before update or delete on sgpt.slot_observation
    for each row execute function sgpt.observation_guard();

alter table sgpt.slot_observation enable row level security;

-- ---------------------------------------------------------------------
-- 4. instrument_observation
--    One row per instrument per slot. The price snapshot at window time.
--    This is the "mandatory market observation for audit and history"
--    required by Section 7 of v1.2 — recorded for all thirteen
--    instruments at every window regardless of whether a trade occurred.
--
--    The OHLCV fields capture the intraday bar up to observation time,
--    plus the prior close. Bot B uses this plus historical data from
--    Polygon (not stored here) to compute its indicators.
-- ---------------------------------------------------------------------
create table sgpt.instrument_observation (
    trade_date        date not null,
    slot_code         text not null,
    instrument_code   text not null references sgpt.instrument (instrument_code),
    last_price        numeric(12,4) not null,
    bid_price         numeric(12,4),
    ask_price         numeric(12,4),
    day_open          numeric(12,4),
    day_high          numeric(12,4),
    day_low           numeric(12,4),
    previous_close    numeric(12,4),
    day_volume        bigint,
    data_source       text not null default 'ibkr',   -- G2-D6: current prices from IBKR
    observed_at       timestamptz not null default now(),
    primary key (trade_date, slot_code, instrument_code),
    constraint instr_obs_slot_fk foreign key (trade_date, slot_code)
        references sgpt.slot_observation (trade_date, slot_code)
);

create trigger instrument_observation_guard_trg
    before update or delete on sgpt.instrument_observation
    for each row execute function sgpt.observation_guard();

alter table sgpt.instrument_observation enable row level security;

-- ---------------------------------------------------------------------
-- 5. bot_a_signal
--    One row per window_run_id. Bot A's macro context output: what the
--    macro environment looks like right now and whether it is safe to
--    trade. Per-instrument blackouts are in the child table bot_a_blackout.
--
--    The event_calendar_snapshot captures exactly what the event calendar
--    showed at the time of this decision, as JSONB, so the decision path
--    can be replayed even if event data is later corrected.
-- ---------------------------------------------------------------------
create table sgpt.bot_a_signal (
    window_run_id          uuid primary key references sgpt.window_run (window_run_id),
    macro_posture          text not null
                             check (macro_posture in ('expansion', 'contraction', 'uncertainty')),
    portfolio_risk_flag    boolean not null default false,
    vix_level              numeric(7,2) not null,
    vix_assessment         text not null
                             check (vix_assessment in ('low', 'elevated', 'high', 'extreme')),
    early_close_no_entries boolean not null default false,
    event_calendar_snapshot jsonb not null default '[]'::jsonb,
        -- array of upcoming events Bot A considered at decision time
    signal_summary         text,            -- plain-English summary for audit log
    created_at             timestamptz not null default now()
);

create trigger bot_a_signal_guard_trg
    before insert or update or delete on sgpt.bot_a_signal
    for each row execute function sgpt.bot_output_guard();

alter table sgpt.bot_a_signal enable row level security;

-- ---------------------------------------------------------------------
-- 6. bot_a_blackout
--    One row per instrument currently in blackout for a given run.
--    Instruments NOT in blackout have no row. Bot A determines blackout
--    periods by applying strategy-specific rules (durations around
--    events) to the market_event data.
-- ---------------------------------------------------------------------
create table sgpt.bot_a_blackout (
    window_run_id        uuid not null references sgpt.bot_a_signal (window_run_id),
    instrument_code      text not null references sgpt.instrument (instrument_code),
    blackout_reason      text not null
                           check (blackout_reason in (
                               'earnings', 'fomc', 'fed_speech',
                               'economic_data', 'ex_dividend', 'other')),
    triggering_event_id  uuid references sgpt.market_event (event_id),
    event_date           date not null,
    blackout_until       date,    -- expected lift date; null if unknown
    note                 text,
    created_at           timestamptz not null default now(),
    primary key (window_run_id, instrument_code)
);

create trigger bot_a_blackout_guard_trg
    before insert or update or delete on sgpt.bot_a_blackout
    for each row execute function sgpt.bot_output_guard();

alter table sgpt.bot_a_blackout enable row level security;

-- ---------------------------------------------------------------------
-- 7. bot_b_scan
--    One row per instrument per window_run_id. Bot B's technical
--    analysis output. Thirteen rows written at every trading window,
--    for every track. This is the workhorse audit table — the record
--    of what the charts were saying at every decision point.
--
--    Indicator columns match the six indicators specified in v1.2
--    Section 5.2: MACD, RSI, Bollinger Bands, Volume, Support and
--    Resistance, ATR. If a strategy revision adds new indicators,
--    a schema migration adds the columns — which is the correct
--    sequence since a new indicator IS a strategy revision.
-- ---------------------------------------------------------------------
create table sgpt.bot_b_scan (
    window_run_id       uuid not null references sgpt.window_run (window_run_id),
    instrument_code     text not null references sgpt.instrument (instrument_code),

    -- MACD (12/26/9 standard, or as configured by strategy revision)
    macd_value          numeric(12,4),
    macd_signal         numeric(12,4),
    macd_histogram      numeric(12,4),

    -- RSI (14-period standard, or as configured)
    rsi_value           numeric(6,2)
                          check (rsi_value between 0 and 100),

    -- Bollinger Bands (20-period/2-sigma standard, or as configured)
    bband_upper         numeric(12,4),
    bband_middle        numeric(12,4),
    bband_lower         numeric(12,4),
    bband_pct_b         numeric(6,4),       -- %B: where price sits (0 = lower, 1 = upper)

    -- Volume
    volume_ratio        numeric(6,2),       -- current vs average volume
    volume_assessment   text not null
                          check (volume_assessment in (
                              'below_average', 'average', 'above_average', 'spike')),

    -- Support and Resistance (primary levels)
    support_level       numeric(12,4),
    resistance_level    numeric(12,4),
    price_to_support    numeric(8,4),       -- distance as percentage
    price_to_resistance numeric(8,4),       -- distance as percentage

    -- ATR
    atr_value           numeric(12,4) not null,
    atr_period          smallint not null default 14,

    -- Bot B's assessment
    trend_direction     text not null
                          check (trend_direction in ('bullish', 'bearish', 'neutral')),
    trend_strength      text not null
                          check (trend_strength in ('weak', 'moderate', 'strong')),
    setup_quality_score numeric(5,2)
                          check (setup_quality_score between 0 and 100),
    has_tradeable_setup boolean not null,
    setup_direction     text
                          check (setup_direction in ('bullish', 'bearish')
                                 or setup_direction is null),
    signal_direction    text
                          check (signal_direction in ('bullish', 'bearish', 'neutral')),

    -- Data provenance
    data_range_start    date,           -- earliest bar used for indicator computation
    bar_count           smallint,       -- number of daily bars used

    scan_summary        text,           -- plain-English summary for audit log
    created_at          timestamptz not null default now(),

    primary key (window_run_id, instrument_code),
    constraint bot_b_setup_direction_chk check (
        (has_tradeable_setup and setup_direction is not null and setup_quality_score is not null)
        or
        (not has_tradeable_setup and setup_direction is null)
    )
);

create index bot_b_scan_setup_idx
    on sgpt.bot_b_scan (instrument_code, created_at desc)
    where has_tradeable_setup;

create trigger bot_b_scan_guard_trg
    before insert or update or delete on sgpt.bot_b_scan
    for each row execute function sgpt.bot_output_guard();

alter table sgpt.bot_b_scan enable row level security;

-- ---------------------------------------------------------------------
-- 8. bot_c_decision
--    One row per instrument per window_run_id. Every instrument gets a
--    decision row at every trading window — either a trade proposal or
--    a pass with a reason code. This means the audit trail has no gaps:
--    for any instrument at any window, there is a row explaining what
--    Bot C decided and why.
--
--    For proposals, headline numbers live in explicit columns so the
--    dashboard can query them directly. The full trade specification
--    (legs, exit plan detail) lives in JSONB columns that Bot D reads
--    as a unit to construct the broker order.
-- ---------------------------------------------------------------------
create table sgpt.bot_c_decision (
    window_run_id         uuid not null references sgpt.window_run (window_run_id),
    instrument_code       text not null references sgpt.instrument (instrument_code),
    decision_type         text not null
                            check (decision_type in ('proposal', 'pass')),

    -- Pass fields (null when decision_type = 'proposal')
    pass_reason           text
                            check (pass_reason in (
                                'no_setup',               -- Bot B found no tradeable setup
                                'active_position',        -- instrument has an open trade
                                'instrument_blackout',    -- Bot A has this instrument blacked out
                                'early_close',            -- early-close day, no new entries
                                'macro_risk',             -- portfolio-level risk flag from Bot A
                                'month_end_proximity',    -- not enough trading days for expected hold
                                'capital_preservation',   -- cap-preservation mode, conviction too low
                                'insufficient_quality',   -- setup exists but score below threshold
                                'max_positions_reached',  -- portfolio capacity reached
                                'insufficient_cash'       -- available cash cannot cover max loss
                            )),

    -- Proposal fields (null when decision_type = 'pass')
    trade_type            text
                            check (trade_type in (
                                'long_call', 'long_put',
                                'bull_call_spread', 'bear_put_spread',
                                'bull_put_spread', 'bear_call_spread',
                                'straddle', 'long_etf')),
    direction             text
                            check (direction in ('bullish', 'bearish', 'neutral')),
    expected_entry_cost   numeric(12,2),     -- total cost to enter
    max_loss              numeric(12,2),     -- worst-case loss
    max_gain              numeric(12,2),     -- best-case gain (null for uncapped)
    breakeven_price       numeric(12,4),     -- primary breakeven
    delta_exposure        numeric(8,4),      -- position delta
    position_quantity     integer,            -- contracts or shares
    position_size_pct     numeric(5,2),      -- as % of portfolio value
    position_value        numeric(12,2),     -- dollar value of position
    expected_hold_days    smallint,
    trading_days_left     smallint,           -- remaining in month at decision time
    conviction_score      numeric(5,2)       -- Bot C's overall conviction
                            check (conviction_score between 0 and 100),

    -- Structured detail for Bot D and audit replay
    legs                  jsonb,
        -- Array of leg objects, each containing:
        --   leg_number, side (buy/sell), instrument_type (option/shares),
        --   option_type (call/put), strike, expiration, quantity,
        --   expected_price, delta
    exit_plan             jsonb,
        -- Object containing:
        --   exit_type (tiered/spread_standard/etf_standard),
        --   targets: [{pct_of_position, trigger_price}],
        --   stop_loss: {trigger_price, pct_from_entry},
        --   thesis_invalidation_note
    proposal_reasoning    text,              -- plain-English justification

    -- Common fields
    decision_summary      text,              -- one-line summary for audit log
    created_at            timestamptz not null default now(),

    primary key (window_run_id, instrument_code),

    -- Mutual exclusivity: proposals have trade details, passes have reasons
    constraint bot_c_proposal_chk check (
        (decision_type = 'proposal'
            and pass_reason is null
            and trade_type is not null
            and direction is not null
            and expected_entry_cost is not null
            and max_loss is not null
            and position_quantity is not null
            and legs is not null
            and exit_plan is not null)
        or
        (decision_type = 'pass'
            and pass_reason is not null
            and trade_type is null
            and legs is null
            and exit_plan is null)
    )
);

create index bot_c_decision_proposals_idx
    on sgpt.bot_c_decision (instrument_code, created_at desc)
    where decision_type = 'proposal';

create trigger bot_c_decision_guard_trg
    before insert or update or delete on sgpt.bot_c_decision
    for each row execute function sgpt.bot_output_guard();

alter table sgpt.bot_c_decision enable row level security;

-- ---------------------------------------------------------------------
-- 9. bot_c_option_candidate
--    One row per option contract that Bot C evaluated during trade
--    construction. These are the contracts from the narrowly bounded
--    IBKR option data pull triggered after Bot B confirms a viable
--    underlying setup.
--
--    Candidates may exist for both proposals and passes: if Bot B found
--    a setup but no option contract met Bot C's criteria, the decision
--    is a pass with reason 'insufficient_quality' and the candidates
--    show what was available.
--
--    If Bot C passed for a reason that precedes the option pull (no
--    setup, active position, blackout, early close), no candidates
--    exist and no rows are written.
-- ---------------------------------------------------------------------
create table sgpt.bot_c_option_candidate (
    candidate_id        bigint generated always as identity primary key,
    window_run_id       uuid not null,
    instrument_code     text not null,
    option_type         text not null check (option_type in ('call', 'put')),
    strike_price        numeric(12,2) not null,
    expiration_date     date not null,
    bid_price           numeric(10,4),
    ask_price           numeric(10,4),
    last_price          numeric(10,4),
    delta               numeric(6,4),
    implied_volatility  numeric(8,4),
    open_interest       integer,
    volume              integer,
    was_selected        boolean not null default false,
    selection_reason    text,        -- why selected or rejected
    pulled_at           timestamptz not null default now(),
    constraint bot_c_candidate_decision_fk
        foreign key (window_run_id, instrument_code)
        references sgpt.bot_c_decision (window_run_id, instrument_code)
);

create index bot_c_candidate_decision_idx
    on sgpt.bot_c_option_candidate (window_run_id, instrument_code);

create trigger bot_c_option_candidate_guard_trg
    before insert or update or delete on sgpt.bot_c_option_candidate
    for each row execute function sgpt.bot_output_guard();

alter table sgpt.bot_c_option_candidate enable row level security;
