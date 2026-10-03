-- =====================================================================
-- SpeculativeGPT — Group 2 invariant tests (Draft G2-D2)
-- D2 changes: fixtures snapshot track_halted, follow the seven-step trading
-- window from G1-D3, and use data_source 'ibkr'.
-- Run against a disposable database AFTER g1_schema.sql, g1_tests.sql
-- (which creates fixture data), and g2_schema.sql.
-- Every block raises an exception if the invariant does NOT hold.
-- Prints "G2 TESTS PASSED" at the end.
-- =====================================================================
\set ON_ERROR_STOP on

-- =====================================================================
-- Fixture data: reuse G1 test fixtures (calendar, broker account, track,
-- plus window runs created by G1 tests). Create a clean running window
-- run for Group 2 tests.
-- =====================================================================

-- We need a running window run to write bot outputs against.
-- G1 tests left some runs in terminal states. Create a fresh one
-- on 2026-09-29, which is in the G1 calendar fixtures but unused.
update sgpt.window_run set status = 'abandoned', finished_at = now(),
    status_detail = 'G2 test fixture cleanup'
where status = 'running';

insert into sgpt.window_run (
    run_type, trigger_source, trade_date, track_code, slot_code, slot_kind,
    scheduled_for, status, strategy_revision_id, broker_account_id,
    account_environment, portfolio_mode, manual_risk_multiplier,
    system_enabled, system_halted, track_halted, code_version,
    ibkr_gateway_version, ibkr_api_version
)
select 'trading_window', 'scheduler', '2026-09-29', t.track_code,
       'W1', 'trading_window',
       ('2026-09-29'::date + '10:30'::time) at time zone 'America/New_York',
       'running', t.strategy_revision_id, t.broker_account_id,
       b.environment, t.portfolio_mode, 1.00, true, false, t.is_halted,
       'g2testsha', '10.37.1', '10.37.2'
from sgpt.trading_track t
join sgpt.broker_account b using (broker_account_id)
where t.track_code = 'PRIMARY';

create temp table g2_fixture as
select window_run_id as run_id
  from sgpt.window_run
 where run_label = '2026-09-29_W1_PRIMARY';

-- =====================================================================
-- Observation layer tests
-- =====================================================================

-- T20: slot_observation can be written for a valid trading date and slot.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.slot_observation (trade_date, slot_code, captured_by_run_id, vix_level)
    values ('2026-09-11', 'W1', v_run, 18.50);
end $$;

-- T21: instrument_observation requires a parent slot_observation.
do $$ begin
    begin
        insert into sgpt.instrument_observation (trade_date, slot_code, instrument_code,
            last_price, data_source)
        values ('2026-09-11', 'W2', 'AAPL', 234.50, 'ibkr');
        raise exception 'T21 FAIL: instrument observation accepted without parent slot observation';
    exception when foreign_key_violation then null;
    end;
end $$;

-- T22: instrument_observation writes successfully with valid parent.
do $$ begin
    insert into sgpt.instrument_observation (trade_date, slot_code, instrument_code,
        last_price, bid_price, ask_price, day_open, day_high, day_low,
        previous_close, day_volume, data_source)
    values ('2026-09-11', 'W1', 'AAPL', 234.50, 234.45, 234.55, 232.00,
            235.10, 231.80, 233.00, 45000000, 'ibkr');
end $$;

-- T23: slot_observation is write-once — updates rejected.
do $$ begin
    begin
        update sgpt.slot_observation set vix_level = 20.00
         where trade_date = '2026-09-11' and slot_code = 'W1';
        raise exception 'T23 FAIL: slot observation update accepted';
    exception when raise_exception then
        if sqlerrm like 'T23 FAIL%' then raise; end if;
    end;
end $$;

-- T24: slot_observation is undeletable.
do $$ begin
    begin
        delete from sgpt.slot_observation
         where trade_date = '2026-09-11' and slot_code = 'W1';
        raise exception 'T24 FAIL: slot observation delete accepted';
    exception when raise_exception then
        if sqlerrm like 'T24 FAIL%' then raise; end if;
    end;
end $$;

-- T25: instrument_observation is write-once — updates rejected.
do $$ begin
    begin
        update sgpt.instrument_observation set last_price = 999.99
         where trade_date = '2026-09-11' and slot_code = 'W1'
           and instrument_code = 'AAPL';
        raise exception 'T25 FAIL: instrument observation update accepted';
    exception when raise_exception then
        if sqlerrm like 'T25 FAIL%' then raise; end if;
    end;
end $$;

-- T26: instrument_observation is undeletable.
do $$ begin
    begin
        delete from sgpt.instrument_observation
         where trade_date = '2026-09-11' and slot_code = 'W1'
           and instrument_code = 'AAPL';
        raise exception 'T26 FAIL: instrument observation delete accepted';
    exception when raise_exception then
        if sqlerrm like 'T26 FAIL%' then raise; end if;
    end;
end $$;

-- T27: duplicate slot_observation for the same slot is rejected (PK).
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.slot_observation (trade_date, slot_code, captured_by_run_id, vix_level)
        values ('2026-09-11', 'W1', v_run, 19.00);
        raise exception 'T27 FAIL: duplicate slot observation accepted';
    exception when unique_violation then null;
    end;
end $$;

-- T28: instrument_code must reference a valid instrument.
do $$ begin
    begin
        insert into sgpt.instrument_observation (trade_date, slot_code, instrument_code,
            last_price, data_source)
        values ('2026-09-11', 'W1', 'FAKESYM', 100.00, 'ibkr');
        raise exception 'T28 FAIL: invalid instrument code accepted';
    exception when foreign_key_violation then null;
    end;
end $$;

-- =====================================================================
-- Bot A output tests
-- =====================================================================

-- Advance steps to bot_a so we can write bot_a_signal.
-- Steps 1 (broker_sync) and 2 (reconciliation) must complete first.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v_run, 'trading_window', 1, 'broker_sync', 'running');
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v_run and step_code = 'broker_sync';

    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v_run, 'trading_window', 2, 'reconciliation', 'running');
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v_run and step_code = 'reconciliation';
end $$;

-- T29: bot_a_signal can be written while the run is running.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.bot_a_signal (window_run_id, macro_posture, portfolio_risk_flag,
        vix_level, vix_assessment, early_close_no_entries,
        event_calendar_snapshot, signal_summary)
    values (v_run, 'expansion', false, 18.50, 'low', false,
            '[{"type": "earnings", "instrument": "AAPL", "date": "2026-10-15"}]'::jsonb,
            'Macro environment clear. No active blackouts.');
end $$;

-- T30: bot_a_signal is write-once — updates rejected.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        update sgpt.bot_a_signal set macro_posture = 'contraction'
         where window_run_id = v_run;
        raise exception 'T30 FAIL: bot_a_signal update accepted';
    exception when raise_exception then
        if sqlerrm like 'T30 FAIL%' then raise; end if;
    end;
end $$;

-- T31: bot_a_signal is undeletable.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        delete from sgpt.bot_a_signal where window_run_id = v_run;
        raise exception 'T31 FAIL: bot_a_signal delete accepted';
    exception when raise_exception then
        if sqlerrm like 'T31 FAIL%' then raise; end if;
    end;
end $$;

-- T32: bot_a_blackout writes for a blacked-out instrument.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.bot_a_blackout (window_run_id, instrument_code,
        blackout_reason, event_date, blackout_until)
    values (v_run, 'AAPL', 'earnings', '2026-10-15', '2026-10-17');
end $$;

-- T33: duplicate blackout for the same instrument in the same run is rejected.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_a_blackout (window_run_id, instrument_code,
            blackout_reason, event_date)
        values (v_run, 'AAPL', 'fomc', '2026-09-18');
        raise exception 'T33 FAIL: duplicate blackout accepted';
    exception when unique_violation then null;
    end;
end $$;

-- =====================================================================
-- Bot B output tests
-- =====================================================================

-- T34: bot_b_scan can be written while the run is running.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.bot_b_scan (window_run_id, instrument_code,
        macd_value, macd_signal, macd_histogram,
        rsi_value, bband_upper, bband_middle, bband_lower, bband_pct_b,
        volume_ratio, volume_assessment,
        support_level, resistance_level, price_to_support, price_to_resistance,
        atr_value, atr_period,
        trend_direction, trend_strength, setup_quality_score,
        has_tradeable_setup, setup_direction, signal_direction,
        data_range_start, bar_count, scan_summary)
    values (v_run, 'MSFT',
        2.45, 1.80, 0.65,
        62.5, 420.00, 410.00, 400.00, 0.72,
        1.35, 'above_average',
        395.00, 425.00, 3.80, 2.40,
        8.50, 14,
        'bullish', 'moderate', 72.5,
        true, 'bullish', 'bullish',
        '2026-07-01', 50,
        'MSFT trending bullish with moderate strength. Setup quality 72.5.');
end $$;

-- T35: bot_b_scan enforces setup direction consistency — tradeable setup
--      requires a direction and score.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_b_scan (window_run_id, instrument_code,
            volume_assessment, atr_value, atr_period,
            trend_direction, trend_strength,
            has_tradeable_setup, setup_direction, setup_quality_score,
            signal_direction)
        values (v_run, 'TSLA',
            'average', 12.00, 14,
            'bearish', 'weak',
            true, null, null,   -- tradeable setup but no direction or score
            'bearish');
        raise exception 'T35 FAIL: tradeable setup without direction accepted';
    exception when check_violation then null;
    end;
end $$;

-- T36: bot_b_scan enforces RSI bounds (0–100).
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_b_scan (window_run_id, instrument_code,
            rsi_value, volume_assessment, atr_value, atr_period,
            trend_direction, trend_strength,
            has_tradeable_setup, signal_direction)
        values (v_run, 'TSLA',
            105.0,    -- invalid RSI
            'average', 12.00, 14,
            'neutral', 'weak', false, 'neutral');
        raise exception 'T36 FAIL: RSI > 100 accepted';
    exception when check_violation then null;
    end;
end $$;

-- T37: bot_b_scan is write-once.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        update sgpt.bot_b_scan set trend_direction = 'bearish'
         where window_run_id = v_run and instrument_code = 'MSFT';
        raise exception 'T37 FAIL: bot_b_scan update accepted';
    exception when raise_exception then
        if sqlerrm like 'T37 FAIL%' then raise; end if;
    end;
end $$;

-- =====================================================================
-- Bot C output tests
-- =====================================================================

-- T38: bot_c_decision pass record writes successfully.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.bot_c_decision (window_run_id, instrument_code,
        decision_type, pass_reason, decision_summary)
    values (v_run, 'AAPL', 'pass', 'instrument_blackout',
            'AAPL in blackout for upcoming earnings.');
end $$;

-- T39: bot_c_decision proposal writes successfully with required fields.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.bot_c_decision (window_run_id, instrument_code,
        decision_type, trade_type, direction,
        expected_entry_cost, max_loss, max_gain, breakeven_price,
        delta_exposure, position_quantity, position_size_pct, position_value,
        expected_hold_days, trading_days_left, conviction_score,
        legs, exit_plan, proposal_reasoning, decision_summary)
    values (v_run, 'MSFT', 'proposal',
        'bull_call_spread', 'bullish',
        350.00, 350.00, 650.00, 413.50,
        0.35, 1, 3.50, 350.00,
        5, 14, 78.5,
        '[{"leg_number": 1, "side": "buy", "instrument_type": "option",
           "option_type": "call", "strike": 410.0, "expiration": "2026-09-26",
           "quantity": 1, "expected_price": 8.50, "delta": 0.55},
          {"leg_number": 2, "side": "sell", "instrument_type": "option",
           "option_type": "call", "strike": 420.0, "expiration": "2026-09-26",
           "quantity": 1, "expected_price": 5.00, "delta": -0.20}]'::jsonb,
        '{"exit_type": "spread_standard",
          "targets": [{"pct_of_position": 100, "trigger_price": 420.0}],
          "stop_loss": {"trigger_price": null, "pct_from_entry": -50},
          "thesis_invalidation_note": "Break below 400 support"}'::jsonb,
        'MSFT bullish setup confirmed. Bull call spread 410/420 offers 1.86:1 reward/risk.',
        'MSFT: Bull call spread 410/420 Sep26, $350 risk, $650 max gain.');
end $$;

-- T40: proposal without required fields is rejected (missing legs).
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_c_decision (window_run_id, instrument_code,
            decision_type, trade_type, direction,
            expected_entry_cost, max_loss, position_quantity,
            legs, exit_plan)
        values (v_run, 'NVDA', 'proposal',
            'long_call', 'bullish',
            500.00, 500.00, 1,
            null,     -- legs missing
            '{"exit_type": "tiered"}'::jsonb);
        raise exception 'T40 FAIL: proposal without legs accepted';
    exception when check_violation then null;
    end;
end $$;

-- T41: pass with trade_type populated is rejected (mutual exclusivity).
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_c_decision (window_run_id, instrument_code,
            decision_type, pass_reason, trade_type)
        values (v_run, 'NVDA', 'pass', 'no_setup', 'long_call');
        raise exception 'T41 FAIL: pass with trade_type accepted';
    exception when check_violation then null;
    end;
end $$;

-- T42: pass without a reason is rejected.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_c_decision (window_run_id, instrument_code,
            decision_type, pass_reason)
        values (v_run, 'NVDA', 'pass', null);
        raise exception 'T42 FAIL: pass without reason accepted';
    exception when check_violation then null;
    end;
end $$;

-- T43: bot_c_option_candidate writes successfully linked to a decision.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    insert into sgpt.bot_c_option_candidate (window_run_id, instrument_code,
        option_type, strike_price, expiration_date,
        bid_price, ask_price, delta, implied_volatility,
        open_interest, volume, was_selected, selection_reason)
    values
        (v_run, 'MSFT', 'call', 410.00, '2026-09-26',
         8.20, 8.80, 0.55, 0.32, 5200, 1800, true,
         'Selected: best delta/spread ratio for target hold'),
        (v_run, 'MSFT', 'call', 415.00, '2026-09-26',
         6.00, 6.50, 0.42, 0.31, 3100, 900, false,
         'Rejected: delta too low for conviction score'),
        (v_run, 'MSFT', 'call', 420.00, '2026-09-26',
         4.80, 5.20, 0.20, 0.30, 4800, 1200, true,
         'Selected: short leg of spread');
end $$;

-- T44: bot_c_option_candidate requires a parent bot_c_decision.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_c_option_candidate (window_run_id, instrument_code,
            option_type, strike_price, expiration_date, was_selected)
        values (v_run, 'GOOGL', 'call', 180.00, '2026-09-26', false);
        raise exception 'T44 FAIL: option candidate without parent decision accepted';
    exception when foreign_key_violation then null;
    end;
end $$;

-- =====================================================================
-- Zombie-write protection tests
-- =====================================================================

-- T45: bot output rejected after run is failed.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    -- Complete exit_placement, then start bot_a and fail it, which cascades to fail the run.
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v_run, 'trading_window', 3, 'exit_placement', 'running');
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = v_run and step_code = 'exit_placement';
    insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
    values (v_run, 'trading_window', 4, 'bot_a', 'running');
    update sgpt.window_run_step set status = 'failed', finished_at = now(),
        error_code = 'TEST_FAILURE'
    where window_run_id = v_run and step_code = 'bot_a';
    -- Run is now failed. Try writing a bot_b_scan.
    begin
        insert into sgpt.bot_b_scan (window_run_id, instrument_code,
            volume_assessment, atr_value, atr_period,
            trend_direction, trend_strength,
            has_tradeable_setup, signal_direction)
        values (v_run, 'GOOGL',
            'average', 5.00, 14, 'neutral', 'weak', false, 'neutral');
        raise exception 'T45 FAIL: bot_b_scan accepted on failed run';
    exception when raise_exception then
        if sqlerrm like 'T45 FAIL%' then raise; end if;
    end;
end $$;

-- T46: bot_a_blackout rejected after run is failed (same guard).
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_a_blackout (window_run_id, instrument_code,
            blackout_reason, event_date)
        values (v_run, 'MSFT', 'fomc', '2026-09-18');
        raise exception 'T46 FAIL: bot_a_blackout accepted on failed run';
    exception when raise_exception then
        if sqlerrm like 'T46 FAIL%' then raise; end if;
    end;
end $$;

-- T47: bot_c_decision rejected after run is failed.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_c_decision (window_run_id, instrument_code,
            decision_type, pass_reason, decision_summary)
        values (v_run, 'META', 'pass', 'no_setup', 'Zombie write attempt');
        raise exception 'T47 FAIL: bot_c_decision accepted on failed run';
    exception when raise_exception then
        if sqlerrm like 'T47 FAIL%' then raise; end if;
    end;
end $$;

-- T48: bot_c_option_candidate rejected after run is failed.
do $$
declare v_run uuid := (select run_id from g2_fixture);
begin
    begin
        insert into sgpt.bot_c_option_candidate (window_run_id, instrument_code,
            option_type, strike_price, expiration_date, was_selected)
        values (v_run, 'MSFT', 'put', 400.00, '2026-09-26', false);
        raise exception 'T48 FAIL: option candidate accepted on failed run';
    exception when raise_exception then
        if sqlerrm like 'T48 FAIL%' then raise; end if;
    end;
end $$;

-- =====================================================================
-- Instrument table tests
-- =====================================================================

-- T49: instrument code must be uppercase letters only.
do $$ begin
    begin
        insert into sgpt.instrument (instrument_code, display_name, asset_class)
        values ('bad_code', 'Invalid', 'equity');
        raise exception 'T49 FAIL: lowercase instrument code accepted';
    exception when check_violation then null;
    end;
end $$;

-- T50: deactivated instrument must have deactivated_at.
do $$ begin
    begin
        insert into sgpt.instrument (instrument_code, display_name, asset_class, is_active)
        values ('TEST', 'Test', 'equity', false);
        raise exception 'T50 FAIL: inactive instrument without deactivated_at accepted';
    exception when check_violation then null;
    end;
end $$;

-- T51: thirteen instruments seeded correctly.
do $$ begin
    if (select count(*) from sgpt.instrument) <> 13 then
        raise exception 'T51 FAIL: expected 13 instruments, got %',
            (select count(*) from sgpt.instrument);
    end if;
    if (select count(*) from sgpt.instrument where asset_class = 'equity') <> 7 then
        raise exception 'T51 FAIL: expected 7 equities';
    end if;
    if (select count(*) from sgpt.instrument where asset_class = 'commodity_etf') <> 6 then
        raise exception 'T51 FAIL: expected 6 commodity ETFs';
    end if;
    if (select count(*) from sgpt.instrument where is_confirmed = false) <> 6 then
        raise exception 'T51 FAIL: expected 6 unconfirmed (commodity ETFs)';
    end if;
end $$;

-- T52: conviction_score on bot_c_decision bounded 0–100.
do $$
declare v_run uuid;
begin
    -- Need a fresh running run since the fixture run was failed in T45.
    insert into sgpt.window_run (
        run_type, trigger_source, trade_date, track_code, slot_code, slot_kind,
        scheduled_for, status, strategy_revision_id, broker_account_id,
        account_environment, portfolio_mode, manual_risk_multiplier,
        system_enabled, system_halted, track_halted, code_version,
        ibkr_gateway_version, ibkr_api_version
    )
    select 'trading_window', 'scheduler', '2026-09-29', t.track_code,
           'W2', 'trading_window',
           ('2026-09-29'::date + '13:00'::time) at time zone 'America/New_York',
           'running', t.strategy_revision_id, t.broker_account_id,
           b.environment, t.portfolio_mode, 1.00, true, false, t.is_halted,
           'g2testsha', '10.37.1', '10.37.2'
    from sgpt.trading_track t
    join sgpt.broker_account b using (broker_account_id)
    where t.track_code = 'PRIMARY'
    returning window_run_id into v_run;

    begin
        insert into sgpt.bot_c_decision (window_run_id, instrument_code,
            decision_type, trade_type, direction,
            expected_entry_cost, max_loss, position_quantity,
            conviction_score,
            legs, exit_plan)
        values (v_run, 'TSLA', 'proposal',
            'long_call', 'bullish',
            500.00, 500.00, 1,
            150.0,   -- invalid: above 100
            '[{"leg_number": 1}]'::jsonb,
            '{"exit_type": "tiered"}'::jsonb);
        raise exception 'T52 FAIL: conviction score > 100 accepted';
    exception when check_violation then null;
    end;
    -- Clean up: abandon the test run.
    update sgpt.window_run set status = 'abandoned', finished_at = now(),
        status_detail = 'T52 cleanup' where window_run_id = v_run;
end $$;

select 'G2 TESTS PASSED' as result;
