-- =====================================================================
-- SpeculativeGPT — Group 3 invariant tests (Draft G3-D2)
-- D2 adds T100–T116 for corrections C-1, C-2, C-3 and C-4.
-- Run against a disposable database AFTER, in order:
--   G1-D4 schema, G1-D4 tests, G2-D2 schema, G2-D2 tests, G3-D2 schema.
-- Every rejection test also checks the error text, so a test cannot pass
-- because some unrelated rule happened to fire.
-- Prints "G3 TESTS PASSED" at the end.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------
create temp table k (name text primary key, id uuid not null);
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;

-- Inside an exception handler: re-raise our own FAIL, or fail if the
-- error is not the one expected.
create function pg_temp.chk(p_test text, p_fragment text, p_msg text) returns void
language plpgsql as $$
begin
    if p_msg like p_test || ' FAIL%' then
        raise exception '%', p_msg;
    end if;
    if position(p_fragment in p_msg) = 0 then
        raise exception '% FAIL: expected error containing [%], got [%]', p_test, p_fragment, p_msg;
    end if;
end $$;

create function pg_temp.new_run(p_name text, p_date date, p_slot text, p_type text,
                                p_track text default 'PRIMARY')
returns uuid language plpgsql as $$
declare v uuid;
begin
    insert into sgpt.window_run (run_type, trigger_source, trade_date, track_code, slot_code, slot_kind,
        scheduled_for, status, strategy_revision_id, broker_account_id, account_environment,
        portfolio_mode, manual_risk_multiplier, system_enabled, system_halted, track_halted,
        code_version, ibkr_gateway_version, ibkr_api_version)
    select p_type,
           case when p_type in ('manual_liquidation', 'owner_resolution') then 'owner' else 'scheduler' end,
           p_date, t.track_code, sl.slot_code, sl.slot_kind,
           case when sl.slot_code is null then null
                else (p_date + sl.scheduled_time_et) at time zone 'America/New_York' end,
           'running', t.strategy_revision_id, t.broker_account_id, b.environment, t.portfolio_mode,
           ss.manual_risk_multiplier, ss.is_enabled, ss.is_halted, t.is_halted,
           'g3testsha', '10.37.1', '10.37.2'
    from sgpt.trading_track t
    join sgpt.broker_account b using (broker_account_id)
    cross join sgpt.system_state ss
    left join sgpt.schedule_slot sl on sl.slot_code = p_slot
    where t.track_code = p_track
    returning window_run_id into v;
    insert into k values (p_name, v);
    return v;
end $$;

-- Completes earlier steps and leaves p_step running.
create function pg_temp.start_step(p_run uuid, p_step text) returns void
language plpgsql as $$
declare v_type text; v_target int; s record;
begin
    select run_type into v_type from sgpt.window_run where window_run_id = p_run;
    select step_seq into v_target from sgpt.run_type_step where run_type = v_type and step_code = p_step;
    update sgpt.window_run_step set status = 'completed', finished_at = now()
     where window_run_id = p_run and status = 'running' and step_seq < v_target;
    for s in select step_seq, step_code from sgpt.run_type_step
              where run_type = v_type and step_seq <= v_target
                and step_seq > (select coalesce(max(step_seq), 0) from sgpt.window_run_step where window_run_id = p_run)
              order by step_seq loop
        insert into sgpt.window_run_step (window_run_id, run_type, step_seq, step_code, status)
        values (p_run, v_type, s.step_seq, s.step_code, 'running');
        if s.step_seq < v_target then
            update sgpt.window_run_step set status = 'completed', finished_at = now()
             where window_run_id = p_run and step_code = s.step_code;
        end if;
    end loop;
end $$;

create function pg_temp.end_run(p_run uuid) returns void language plpgsql as $$
begin
    update sgpt.window_run set status = 'abandoned', finished_at = now(), status_detail = 'G3 test cleanup'
     where window_run_id = p_run and status = 'running';
    update sgpt.window_run_step set status = 'abandoned', finished_at = now()
     where window_run_id = p_run and status = 'running';
end $$;

create function pg_temp.proposal(p_run uuid, p_instr text, p_type text) returns void language sql as $$
    insert into sgpt.bot_c_decision (window_run_id, instrument_code, decision_type, trade_type, direction,
        expected_entry_cost, max_loss, position_quantity, legs, exit_plan, decision_summary)
    values (p_run, p_instr, 'proposal', p_type,
            case when p_type in ('long_put', 'bear_put_spread', 'bear_call_spread') then 'bearish' else 'bullish' end,
            350, 350, 2, '[]'::jsonb, '{}'::jsonb, 'G3 test proposal')
$$;

create function pg_temp.verify(p_run uuid, p_instr text, p_outcome text default 'submitted',
                               p_variance numeric default 2.86) returns void language sql as $$
    insert into sgpt.bot_d_verification (window_run_id, instrument_code, live_entry_cost, cost_variance_pct,
        cost_tolerance_pct, available_cash, cash_covers_max_loss, portfolio_mode_ok, blackout_clear, outcome)
    values (p_run, p_instr, 360, p_variance, 5.00, 15000, true, true, true, p_outcome)
$$;

create function pg_temp.new_trade(p_name text, p_run uuid, p_instr text, p_qty int) returns uuid
language plpgsql as $$
declare v uuid;
begin
    insert into sgpt.trade (window_run_id, track_code, broker_account_id, instrument_code, trade_date,
        trade_type, direction, requested_quantity, updated_by_window_run_id)
    select r.window_run_id, r.track_code, r.broker_account_id, p_instr, r.trade_date,
           d.trade_type, d.direction, p_qty, r.window_run_id
    from sgpt.window_run r
    join sgpt.bot_c_decision d on d.window_run_id = r.window_run_id and d.instrument_code = p_instr
    where r.window_run_id = p_run
    returning trade_id into v;
    if v is null then raise exception 'test helper: no proposal for % in run', p_instr; end if;
    insert into k values (p_name, v);
    return v;
end $$;

create function pg_temp.add_legs(p_trade uuid, p_exp date default '2026-10-16') returns void
language plpgsql as $$
declare t sgpt.trade;
begin
    select * into t from sgpt.trade where trade_id = p_trade;
    insert into sgpt.trade_leg (trade_id, leg_number, sec_type, ibkr_con_id, symbol, option_right, strike, expiration, entry_action)
    values (p_trade, 1, 'OPT', abs(hashtext(t.trade_ref || '1')), t.instrument_code, 'C', 100, p_exp, 'BUY');
    if t.trade_type not in ('long_call', 'long_put') then
        insert into sgpt.trade_leg (trade_id, leg_number, sec_type, ibkr_con_id, symbol, option_right, strike, expiration, entry_action)
        values (p_trade, 2, 'OPT', abs(hashtext(t.trade_ref || '2')), t.instrument_code, 'C', 110, p_exp, 'SELL');
    end if;
end $$;

create function pg_temp.entry(p_name text, p_trade uuid, p_qty int default null,
                              p_good_till timestamptz default null) returns uuid
language plpgsql as $$
declare v uuid;
begin
    insert into sgpt.broker_order (trade_id, broker_account_id, order_role, action, order_type, limit_price,
        time_in_force, good_till, quantity, submitted_by_window_run_id, last_synced_by_window_run_id)
    select t.trade_id, t.broker_account_id, 'entry', 'BUY', 'LMT', 1.75, 'GTD',
           coalesce(p_good_till, (t.trade_date + s.entry_order_expiry_et) at time zone 'America/New_York'),
           coalesce(p_qty, t.requested_quantity), t.window_run_id, t.window_run_id
    from sgpt.trade t
    join sgpt.window_run r on r.window_run_id = t.window_run_id
    join sgpt.schedule_slot s on s.slot_code = r.slot_code
    where t.trade_id = p_trade
    returning broker_order_id into v;
    insert into k values (p_name, v);
    return v;
end $$;

create function pg_temp.exit_order(p_name text, p_trade uuid, p_run uuid, p_role text, p_qty int,
                                   p_action text default 'SELL') returns uuid
language plpgsql as $$
declare v uuid;
begin
    insert into sgpt.broker_order (trade_id, broker_account_id, order_role, exit_tier, oca_group, action,
        order_type, limit_price, stop_price, time_in_force, quantity,
        submitted_by_window_run_id, last_synced_by_window_run_id)
    select t.trade_id, t.broker_account_id, p_role, 1, 'OCA-' || t.trade_ref, p_action,
           case p_role when 'exit_target' then 'LMT' else 'STP' end,
           case p_role when 'exit_target' then 3.00 end,
           case p_role when 'exit_stop' then 0.90 end,
           'GTC', p_qty, p_run, p_run
    from sgpt.trade t where t.trade_id = p_trade
    returning broker_order_id into v;
    insert into k values (p_name, v);
    return v;
end $$;

create function pg_temp.close_order(p_name text, p_trade uuid, p_run uuid, p_event uuid, p_seq int,
                                    p_qty int, p_action text default 'SELL') returns uuid
language plpgsql as $$
declare v uuid;
begin
    insert into sgpt.broker_order (trade_id, broker_account_id, order_role, action, order_type, limit_price,
        time_in_force, quantity, liquidation_event_id, liquidation_item_seq,
        submitted_by_window_run_id, last_synced_by_window_run_id)
    select t.trade_id, t.broker_account_id, 'close', p_action, 'LMT', 1.20, 'DAY', p_qty, p_event, p_seq, p_run, p_run
    from sgpt.trade t where t.trade_id = p_trade
    returning broker_order_id into v;
    insert into k values (p_name, v);
    return v;
end $$;

-- Broker Sync recording an order status.
create function pg_temp.sync(p_order uuid, p_run uuid, p_status text, p_filled int) returns void
language sql as $$
    update sgpt.broker_order
       set status = p_status, filled_quantity = p_filled,
           avg_fill_price = case when p_filled > 0 then 1.75 end,
           finished_at = case when sgpt.order_is_working(p_status) then null else now() end,
           last_synced_by_window_run_id = p_run
     where broker_order_id = p_order
$$;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into sgpt.market_calendar (trade_date, is_trading_day, market_open_et, market_close_et, is_early_close, source)
values ('2026-12-24', true, '09:30', '13:00', true, 'test');

select pg_temp.new_run('runA', '2026-09-10', 'W2', 'trading_window');
select pg_temp.start_step(pg_temp.id('runA'), 'bot_c');
select pg_temp.proposal(pg_temp.id('runA'), i, tt)
  from (values ('MSFT', 'bull_call_spread'), ('NVDA', 'bull_call_spread'), ('GOOGL', 'long_call'),
               ('AAPL', 'long_call'), ('META', 'long_call'), ('TSLA', 'bull_call_spread'),
               ('AMZN', 'long_call')) v(i, tt);
insert into sgpt.bot_c_decision (window_run_id, instrument_code, decision_type, pass_reason)
values (pg_temp.id('runA'), 'XME', 'pass', 'no_setup');
select pg_temp.start_step(pg_temp.id('runA'), 'bot_d');

-- =====================================================================
-- Bot D verification
-- =====================================================================

-- T53: a submitted verification must have passed every check (8% > 5% tolerance).
do $$ begin
    begin
        perform pg_temp.verify(pg_temp.id('runA'), 'MSFT', 'submitted', 8.00);
        raise exception 'T53 FAIL: submission outside cost tolerance accepted';
    exception when others then perform pg_temp.chk('T53', 'bot_d_submitted_chk', sqlerrm);
    end;
end $$;

-- T54: Bot D cannot verify a Bot C pass.
do $$ begin
    begin
        perform pg_temp.verify(pg_temp.id('runA'), 'XME');
        raise exception 'T54 FAIL: verification of a pass accepted';
    exception when others then perform pg_temp.chk('T54', 'bot_d_verification_proposal_fk', sqlerrm);
    end;
end $$;

-- T55: a trade cannot exist for a proposal Bot D killed.
do $$ begin
    perform pg_temp.verify(pg_temp.id('runA'), 'AMZN', 'killed_cost_tolerance', 8.00);
    begin
        perform pg_temp.new_trade('x', pg_temp.id('runA'), 'AMZN', 1);
        raise exception 'T55 FAIL: trade for a killed proposal accepted';
    exception when others then perform pg_temp.chk('T55', 'trade_verification_fk', sqlerrm);
    end;
end $$;

select pg_temp.verify(pg_temp.id('runA'), i)
  from unnest(array['MSFT', 'NVDA', 'GOOGL', 'AAPL', 'META', 'TSLA']) i;

-- =====================================================================
-- Trades, legs, entry orders
-- =====================================================================

-- T56: a trade gets its permanent reference; its entry order ref derives from it.
do $$
declare v_t uuid; v_o uuid;
begin
    v_t := pg_temp.new_trade('tMSFT', pg_temp.id('runA'), 'MSFT', 2);
    perform pg_temp.add_legs(v_t);
    v_o := pg_temp.entry('eMSFT', v_t);
    if (select trade_ref from sgpt.trade where trade_id = v_t) <> 'SG-260910-W2-PRIMARY-MSFT' then
        raise exception 'T56 FAIL: unexpected trade_ref %', (select trade_ref from sgpt.trade where trade_id = v_t);
    end if;
    if (select order_ref from sgpt.broker_order where broker_order_id = v_o) <> 'SG-260910-W2-PRIMARY-MSFT-E1' then
        raise exception 'T56 FAIL: unexpected order_ref';
    end if;
end $$;

-- T57: an option expiring on the last trading day of the month is rejected (G3-D6).
do $$ begin
    begin
        perform pg_temp.add_legs(pg_temp.new_trade('x', pg_temp.id('runA'), 'META', 1), '2026-09-30');
        raise exception 'T57 FAIL: option expiring on the last trading day accepted';
    exception when others then perform pg_temp.chk('T57', 'on or before the last trading day', sqlerrm);
    end;
end $$;

-- T58: a spread entry order with only one leg recorded is rejected.
do $$
declare v_t uuid;
begin
    begin
        v_t := pg_temp.new_trade('x', pg_temp.id('runA'), 'TSLA', 1);
        insert into sgpt.trade_leg (trade_id, leg_number, sec_type, ibkr_con_id, symbol, option_right, strike, expiration, entry_action)
        values (v_t, 1, 'OPT', 999001, 'TSLA', 'C', 300, '2026-10-16', 'BUY');
        perform pg_temp.entry('x2', v_t);
        raise exception 'T58 FAIL: one-legged spread entry accepted';
    exception when others then perform pg_temp.chk('T58', '1 legs recorded, 2 required', sqlerrm);
    end;
end $$;

-- T59: an entry order may not expire after its window's entry expiry.
do $$
declare v_t uuid;
begin
    begin
        v_t := pg_temp.new_trade('x', pg_temp.id('runA'), 'GOOGL', 1);
        perform pg_temp.add_legs(v_t);
        perform pg_temp.entry('x2', v_t, null, ('2026-09-10'::date + time '15:00') at time zone 'America/New_York');
        raise exception 'T59 FAIL: entry expiring after window expiry accepted';
    exception when others then perform pg_temp.chk('T59', 'later than the window expiry', sqlerrm);
    end;
end $$;

-- T60: entry order quantity must equal the trade's requested quantity.
do $$
declare v_t uuid;
begin
    begin
        v_t := pg_temp.new_trade('x', pg_temp.id('runA'), 'GOOGL', 1);
        perform pg_temp.add_legs(v_t);
        perform pg_temp.entry('x2', v_t, 5);
        raise exception 'T60 FAIL: mismatched entry quantity accepted';
    exception when others then perform pg_temp.chk('T60', 'must equal requested quantity', sqlerrm);
    end;
end $$;

-- T61: legs cannot be added once the entry order exists.
do $$ begin
    begin
        insert into sgpt.trade_leg (trade_id, leg_number, sec_type, ibkr_con_id, symbol, option_right, strike, expiration, entry_action)
        values (pg_temp.id('tMSFT'), 3, 'OPT', 999002, 'MSFT', 'C', 120, '2026-10-16', 'BUY');
        raise exception 'T61 FAIL: leg added after entry order';
    exception when others then perform pg_temp.chk('T61', 'legs must be written before the entry order', sqlerrm);
    end;
end $$;

-- T62: the global Halt blocks trade creation.
do $$ begin
    begin
        update sgpt.system_state set is_halted = true, halted_at = now(), halt_reason = 'T62';
        perform pg_temp.new_trade('x', pg_temp.id('runA'), 'TSLA', 1);
        raise exception 'T62 FAIL: trade created during global Halt';
    exception when others then perform pg_temp.chk('T62', 'global Halt is on', sqlerrm);
    end;
end $$;

-- T63: a track Halt set after the trade was created still blocks the entry order.
do $$
declare v_t uuid;
begin
    begin
        v_t := pg_temp.new_trade('x', pg_temp.id('runA'), 'GOOGL', 1);
        perform pg_temp.add_legs(v_t);
        update sgpt.trading_track set is_halted = true, halted_at = now(), halt_reason = 'T63'
         where track_code = 'PRIMARY';
        perform pg_temp.entry('x2', v_t);
        raise exception 'T63 FAIL: entry order sent while track halted';
    exception when others then perform pg_temp.chk('T63', 'track PRIMARY is halted', sqlerrm);
    end;
end $$;

-- Fixture: three more trades with entry orders.
select pg_temp.add_legs(pg_temp.new_trade('tNVDA',  pg_temp.id('runA'), 'NVDA',  2));
select pg_temp.add_legs(pg_temp.new_trade('tGOOGL', pg_temp.id('runA'), 'GOOGL', 1));
select pg_temp.add_legs(pg_temp.new_trade('tAAPL',  pg_temp.id('runA'), 'AAPL',  1));
select pg_temp.entry('eNVDA', pg_temp.id('tNVDA')), pg_temp.entry('eGOOGL', pg_temp.id('tGOOGL')),
       pg_temp.entry('eAAPL', pg_temp.id('tAAPL'));

-- T64: exit orders are rejected outside the exit_placement step.
do $$ begin
    begin
        perform pg_temp.exit_order('x', pg_temp.id('tMSFT'), pg_temp.id('runA'), 'exit_target', 1);
        raise exception 'T64 FAIL: exit order accepted during bot_d';
    exception when others then perform pg_temp.chk('T64', 'exit_placement', sqlerrm);
    end;
end $$;

-- T65: a trade cannot open while its entry order is still working (partial fill).
do $$ begin
    perform pg_temp.sync(pg_temp.id('eNVDA'), pg_temp.id('runA'), 'working', 1);
    begin
        update sgpt.trade set status = 'open', opened_at = now(), updated_by_window_run_id = pg_temp.id('runA')
         where trade_id = pg_temp.id('tNVDA');
        raise exception 'T65 FAIL: trade opened while entry still working';
    exception when others then perform pg_temp.chk('T65', 'open requires a finished entry order', sqlerrm);
    end;
end $$;

-- Fixture: entries finish. MSFT fills 2; NVDA partial 1 of 2 then expires;
-- GOOGL fills 1; AAPL expires unfilled.
select pg_temp.sync(pg_temp.id('eMSFT'),  pg_temp.id('runA'), 'filled', 2);
select pg_temp.sync(pg_temp.id('eNVDA'),  pg_temp.id('runA'), 'expired', 1);
select pg_temp.sync(pg_temp.id('eGOOGL'), pg_temp.id('runA'), 'filled', 1);
select pg_temp.sync(pg_temp.id('eAAPL'),  pg_temp.id('runA'), 'expired', 0);
update sgpt.trade set status = 'open', updated_by_window_run_id = pg_temp.id('runA'),
       opened_at = case instrument_code when 'MSFT' then timestamptz '2026-09-10 17:05Z'
                                        when 'NVDA' then timestamptz '2026-09-10 17:10Z'
                                        else timestamptz '2026-09-10 17:20Z' end
 where trade_id in (pg_temp.id('tMSFT'), pg_temp.id('tNVDA'), pg_temp.id('tGOOGL'));
update sgpt.trade set status = 'not_opened', updated_by_window_run_id = pg_temp.id('runA')
 where trade_id = pg_temp.id('tAAPL');

-- T66: a finished order cannot be changed (no rewriting fills after the fact).
do $$ begin
    begin
        perform pg_temp.sync(pg_temp.id('eMSFT'), pg_temp.id('runA'), 'filled', 2);
        update sgpt.broker_order set status_detail = 'rewrite' where broker_order_id = pg_temp.id('eMSFT');
        raise exception 'T66 FAIL: finished order modified';
    exception when others then perform pg_temp.chk('T66', 'is final', sqlerrm);
    end;
end $$;

-- T67: a not_opened trade is final.
do $$ begin
    begin
        update sgpt.trade set status_detail = 'rewrite', updated_by_window_run_id = pg_temp.id('runA')
         where trade_id = pg_temp.id('tAAPL');
        raise exception 'T67 FAIL: not_opened trade modified';
    exception when others then perform pg_temp.chk('T67', 'is final', sqlerrm);
    end;
end $$;

-- T68: each IBKR execution is recorded exactly once.
do $$
declare v_acct uuid := (select broker_account_id from sgpt.trade where trade_id = pg_temp.id('tMSFT'));
begin
    insert into sgpt.broker_execution (broker_account_id, ibkr_exec_id, broker_order_id, reported_order_ref,
        ibkr_con_id, symbol, sec_type, option_right, strike, expiration, side, quantity, price,
        executed_at, recorded_by_window_run_id)
    values (v_acct, '0000e1a7.65f1.01.01', pg_temp.id('eMSFT'), 'SG-260910-W2-PRIMARY-MSFT-E1',
            111, 'MSFT', 'OPT', 'C', 100, '2026-10-16', 'BOT', 2, 3.10, now(), pg_temp.id('runA')),
           (v_acct, '0000e1a7.65f2.01.01', pg_temp.id('eMSFT'), 'SG-260910-W2-PRIMARY-MSFT-E1',
            112, 'MSFT', 'OPT', 'C', 110, '2026-10-16', 'SLD', 2, 1.35, now(), pg_temp.id('runA'));
    begin
        insert into sgpt.broker_execution (broker_account_id, ibkr_exec_id, broker_order_id,
            ibkr_con_id, symbol, sec_type, side, quantity, price, executed_at, recorded_by_window_run_id)
        values (v_acct, '0000e1a7.65f1.01.01', pg_temp.id('eMSFT'),
                111, 'MSFT', 'OPT', 'BOT', 2, 3.10, now(), pg_temp.id('runA'));
        raise exception 'T68 FAIL: duplicate execution ID accepted';
    exception when others then perform pg_temp.chk('T68', 'broker_execution_exec_id_uq', sqlerrm);
    end;
end $$;

-- T69: an unmatched execution (e.g. a manual trade) is recorded, not dropped;
--      its commission can be added once and only once.
do $$
declare v_acct uuid := (select broker_account_id from sgpt.trade where trade_id = pg_temp.id('tMSFT'));
begin
    insert into sgpt.broker_execution (broker_account_id, ibkr_exec_id, ibkr_con_id, symbol, sec_type,
        side, quantity, price, executed_at, recorded_by_window_run_id)
    values (v_acct, 'MANUAL.0001', 756733, 'SPY', 'STK', 'BOT', 10, 560.00, now(), pg_temp.id('runA'));
    update sgpt.broker_execution set commission = 1.00, commission_currency = 'USD', commission_recorded_at = now()
     where ibkr_exec_id = 'MANUAL.0001';
    begin
        update sgpt.broker_execution set commission = 0.01, commission_recorded_at = now()
         where ibkr_exec_id = 'MANUAL.0001';
        raise exception 'T69 FAIL: commission rewritten';
    exception when others then perform pg_temp.chk('T69', 'commission already recorded', sqlerrm);
    end;
end $$;

-- T70: a trade cannot be marked closed while quantity is still open.
do $$ begin
    begin
        update sgpt.trade set status = 'closed', closed_at = now(), close_reason = 'target',
               updated_by_window_run_id = pg_temp.id('runA')
         where trade_id = pg_temp.id('tMSFT');
        raise exception 'T70 FAIL: trade closed with open quantity';
    exception when others then perform pg_temp.chk('T70', 'closed requires zero open quantity', sqlerrm);
    end;
end $$;

select pg_temp.end_run(pg_temp.id('runA'));

-- T71: late writes from an abandoned run are rejected (trade and execution).
do $$
declare v_acct uuid := (select broker_account_id from sgpt.trade where trade_id = pg_temp.id('tMSFT'));
begin
    begin
        update sgpt.trade set status_detail = 'zombie', updated_by_window_run_id = pg_temp.id('runA')
         where trade_id = pg_temp.id('tMSFT');
        raise exception 'T71 FAIL: zombie trade update accepted';
    exception when others then perform pg_temp.chk('T71', 'late write', sqlerrm);
    end;
    begin
        insert into sgpt.broker_execution (broker_account_id, ibkr_exec_id, ibkr_con_id, symbol, sec_type,
            side, quantity, price, executed_at, recorded_by_window_run_id)
        values (v_acct, 'ZOMBIE.0001', 1, 'MSFT', 'OPT', 'SLD', 1, 1.00, now(), pg_temp.id('runA'));
        raise exception 'T71 FAIL: zombie execution accepted';
    exception when others then perform pg_temp.chk('T71', 'late write', sqlerrm);
    end;
end $$;

-- =====================================================================
-- Exit placement (checkpoint run)
-- =====================================================================
select pg_temp.new_run('runB', '2026-09-10', 'V2', 'verification_checkpoint');
select pg_temp.start_step(pg_temp.id('runB'), 'exit_placement');

-- T72: trades cannot be created outside Bot D's step.
do $$ begin
    begin
        insert into sgpt.trade (window_run_id, track_code, broker_account_id, instrument_code, trade_date,
            trade_type, direction, requested_quantity, updated_by_window_run_id)
        select window_run_id, track_code, broker_account_id, 'TSLA', trade_date, 'long_call', 'bullish', 1, window_run_id
          from sgpt.window_run where window_run_id = pg_temp.id('runB');
        raise exception 'T72 FAIL: trade created in a checkpoint';
    exception when others then perform pg_temp.chk('T72', 'bot_d', sqlerrm);
    end;
end $$;

select pg_temp.exit_order('xMSFT_T', pg_temp.id('tMSFT'), pg_temp.id('runB'), 'exit_target', 2);
select pg_temp.exit_order('xMSFT_S', pg_temp.id('tMSFT'), pg_temp.id('runB'), 'exit_stop', 2);

-- T73: working exits can never add up to more than the open quantity.
do $$ begin
    begin
        perform pg_temp.exit_order('x', pg_temp.id('tMSFT'), pg_temp.id('runB'), 'exit_target', 1);
        raise exception 'T73 FAIL: exit quantity above open quantity accepted';
    exception when others then perform pg_temp.chk('T73', 'exceeds open quantity', sqlerrm);
    end;
end $$;

-- T74: no exits on a trade that never opened.
do $$ begin
    begin
        perform pg_temp.exit_order('x', pg_temp.id('tAAPL'), pg_temp.id('runB'), 'exit_stop', 1);
        raise exception 'T74 FAIL: exit on not_opened trade accepted';
    exception when others then perform pg_temp.chk('T74', 'exits are only placed on open trades', sqlerrm);
    end;
end $$;

-- T75: an exit must be the opposite action of the entry (never adds to the position).
do $$ begin
    begin
        perform pg_temp.exit_order('x', pg_temp.id('tNVDA'), pg_temp.id('runB'), 'exit_target', 1, 'BUY');
        raise exception 'T75 FAIL: same-direction exit accepted';
    exception when others then perform pg_temp.chk('T75', 'opposite the entry', sqlerrm);
    end;
end $$;

select pg_temp.exit_order('xNVDA_T', pg_temp.id('tNVDA'), pg_temp.id('runB'), 'exit_target', 1);
select pg_temp.exit_order('xNVDA_S', pg_temp.id('tNVDA'), pg_temp.id('runB'), 'exit_stop', 1);

-- T76: the unprotected-positions view lists only GOOGL (open, no exits).
do $$ begin
    if (select array_agg(instrument_code) from sgpt.unprotected_open_trade_v where track_code = 'PRIMARY')
       is distinct from array['GOOGL'] then
        raise exception 'T76 FAIL: unprotected view returned %',
            (select array_agg(instrument_code) from sgpt.unprotected_open_trade_v);
    end if;
end $$;

select pg_temp.end_run(pg_temp.id('runB'));

-- =====================================================================
-- One active trade per instrument, per track (G3-D2)
-- =====================================================================
select pg_temp.new_run('runD', '2026-09-11', 'W2', 'trading_window');
select pg_temp.start_step(pg_temp.id('runD'), 'bot_d');
select pg_temp.proposal(pg_temp.id('runD'), 'MSFT', 'bull_call_spread');
select pg_temp.verify(pg_temp.id('runD'), 'MSFT');

-- T77: a second active MSFT trade on the same track is rejected.
do $$ begin
    begin
        perform pg_temp.new_trade('x', pg_temp.id('runD'), 'MSFT', 1);
        raise exception 'T77 FAIL: second active MSFT trade on PRIMARY accepted';
    exception when others then perform pg_temp.chk('T77', 'trade_one_active_per_track_instrument_uq', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runD'));

-- T78: the candidate track, on its own account, may hold MSFT at the same time.
insert into sgpt.broker_account (ibkr_account_id, environment, legal_owner, display_name, credential_ref)
values ('DU0000002', 'paper', 'personal', 'Candidate paper', 'IBKR_PERSONAL_PAPER_2');
insert into sgpt.trading_track (track_code, role, broker_account_id, strategy_revision_id, run_priority)
select 'CANDIDATE', 'candidate', broker_account_id, 'R-20260901-MULTI-01', 2
  from sgpt.broker_account where ibkr_account_id = 'DU0000002';
select pg_temp.new_run('runDC', '2026-09-11', 'W2', 'trading_window', 'CANDIDATE');
select pg_temp.start_step(pg_temp.id('runDC'), 'bot_d');
select pg_temp.proposal(pg_temp.id('runDC'), 'MSFT', 'bull_call_spread');
select pg_temp.verify(pg_temp.id('runDC'), 'MSFT');
do $$ begin
    perform pg_temp.new_trade('tMSFT_C', pg_temp.id('runDC'), 'MSFT', 1);
    if (select count(*) from sgpt.trade where instrument_code = 'MSFT'
          and status in ('entry_working', 'open', 'closing')) <> 2 then
        raise exception 'T78 FAIL: expected one active MSFT trade on each track';
    end if;
end $$;
select pg_temp.end_run(pg_temp.id('runDC'));

-- =====================================================================
-- Reconciliation failure: single instrument, cancel-exits-first
-- =====================================================================
select pg_temp.new_run('runC', '2026-09-29', 'W3', 'trading_window');
select pg_temp.start_step(pg_temp.id('runC'), 'reconciliation');

-- T79: a recheck is not allowed without a first check that found a mismatch.
do $$ begin
    begin
        insert into sgpt.reconciliation_check (window_run_id, check_seq, result, mismatch_count, expected_positions, actual_positions)
        values (pg_temp.id('runC'), 2, 'match', 0, '[]', '[]');
        raise exception 'T79 FAIL: recheck without first mismatch accepted';
    exception when others then perform pg_temp.chk('T79', 'recheck is only allowed', sqlerrm);
    end;
end $$;

insert into sgpt.reconciliation_check (window_run_id, check_seq, result, mismatch_count, expected_positions, actual_positions)
values (pg_temp.id('runC'), 1, 'mismatch', 1, '[{"MSFT": 2}]', '[{"MSFT": 1}]'),
       (pg_temp.id('runC'), 2, 'mismatch', 1, '[{"MSFT": 2}]', '[{"MSFT": 1}]');
insert into sgpt.reconciliation_mismatch (window_run_id, check_seq, symbol, instrument_code, trade_id, expected_detail, actual_detail)
values (pg_temp.id('runC'), 1, 'MSFT', 'MSFT', pg_temp.id('tMSFT'), '{"qty": 2}', '{"qty": 1}'),
       (pg_temp.id('runC'), 2, 'MSFT', 'MSFT', pg_temp.id('tMSFT'), '{"qty": 2}', '{"qty": 1}');

-- T80: Halt first — the liquidation cannot be recorded before the track Halt is set.
do $$ begin
    begin
        insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope, reconciliation_check_seq)
        values (pg_temp.id('runC'), 'PRIMARY', 'reconciliation', 'reconciliation_single', 'aggressive', 'track', 2);
        raise exception 'T80 FAIL: liquidation recorded before Halt';
    exception when others then perform pg_temp.chk('T80', 'set the track Halt before', sqlerrm);
    end;
end $$;

-- T81: one confirmed mismatch cannot be recorded as a systemic failure.
do $$ begin
    begin
        update sgpt.trading_track set is_halted = true, halted_at = now(), halt_reason = 'T81',
               halted_by_window_run_id = pg_temp.id('runC') where track_code = 'PRIMARY';
        insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope, reconciliation_check_seq)
        values (pg_temp.id('runC'), 'PRIMARY', 'reconciliation', 'reconciliation_systemic', 'aggressive', 'track', 2);
        raise exception 'T81 FAIL: systemic trigger on one mismatch accepted';
    exception when others then perform pg_temp.chk('T81', 'does not match 1 confirmed mismatch', sqlerrm);
    end;
end $$;

update sgpt.trading_track set is_halted = true, halted_at = now(),
       halt_reason = 'Reconciliation mismatch confirmed on MSFT', halted_by_window_run_id = pg_temp.id('runC')
 where track_code = 'PRIMARY';
insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope, reconciliation_check_seq)
values (pg_temp.id('runC'), 'PRIMARY', 'reconciliation', 'reconciliation_single', 'aggressive', 'track', 2);
insert into k select 'evC', liquidation_event_id from sgpt.liquidation_event where window_run_id = pg_temp.id('runC');

-- T82: a single-instrument liquidation may only close the mismatched instrument.
do $$ begin
    begin
        insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
        values (pg_temp.id('evC'), 1, pg_temp.id('tNVDA'), now());
        raise exception 'T82 FAIL: unrelated position added to single-instrument liquidation';
    exception when others then perform pg_temp.chk('T82', 'may only close the mismatched instrument', sqlerrm);
    end;
end $$;

insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
values (pg_temp.id('evC'), 1, pg_temp.id('tMSFT'), now());
update sgpt.trade set status = 'closing', closing_started_at = now(), close_reason = 'reconciliation_single',
       updated_by_window_run_id = pg_temp.id('runC')
 where trade_id = pg_temp.id('tMSFT');
update sgpt.liquidation_item set status = 'cancelling_orders', started_at = now()
 where liquidation_event_id = pg_temp.id('evC') and item_seq = 1;

-- T83: cancel-exits-first — no close order while exit orders are still working.
do $$ begin
    begin
        perform pg_temp.close_order('x', pg_temp.id('tMSFT'), pg_temp.id('runC'), pg_temp.id('evC'), 1, 1);
        raise exception 'T83 FAIL: close order sent while exits working';
    exception when others then perform pg_temp.chk('T83', 'still working — cancel and confirm them first', sqlerrm);
    end;
end $$;

-- Fixture: cancel the target; the stop fills 1 contract before its cancel lands.
select pg_temp.sync(pg_temp.id('xMSFT_T'), pg_temp.id('runC'), 'cancel_requested', 0);
select pg_temp.sync(pg_temp.id('xMSFT_S'), pg_temp.id('runC'), 'cancel_requested', 0);
select pg_temp.sync(pg_temp.id('xMSFT_T'), pg_temp.id('runC'), 'cancelled', 0);
select pg_temp.sync(pg_temp.id('xMSFT_S'), pg_temp.id('runC'), 'cancelled', 1);

-- T84: never close more than is held (1 remains after the stop's partial fill).
do $$ begin
    begin
        perform pg_temp.close_order('x', pg_temp.id('tMSFT'), pg_temp.id('runC'), pg_temp.id('evC'), 1, 2);
        raise exception 'T84 FAIL: close larger than open quantity accepted';
    exception when others then perform pg_temp.chk('T84', 'exceeds open quantity 1', sqlerrm);
    end;
end $$;

-- T85: a close must be the opposite action of the entry.
do $$ begin
    begin
        perform pg_temp.close_order('x', pg_temp.id('tMSFT'), pg_temp.id('runC'), pg_temp.id('evC'), 1, 1, 'BUY');
        raise exception 'T85 FAIL: same-direction close accepted';
    exception when others then perform pg_temp.chk('T85', 'opposite the entry', sqlerrm);
    end;
end $$;

-- T86: the correct close completes the sequence end to end.
do $$ begin
    perform pg_temp.close_order('cMSFT', pg_temp.id('tMSFT'), pg_temp.id('runC'), pg_temp.id('evC'), 1, 1);
    if (select order_ref from sgpt.broker_order where broker_order_id = pg_temp.id('cMSFT'))
       <> 'SG-260910-W2-PRIMARY-MSFT-C1' then
        raise exception 'T86 FAIL: unexpected close order_ref';
    end if;
    update sgpt.liquidation_item set status = 'close_submitted'
     where liquidation_event_id = pg_temp.id('evC') and item_seq = 1;
    perform pg_temp.sync(pg_temp.id('cMSFT'), pg_temp.id('runC'), 'filled', 1);
    update sgpt.trade set status = 'closed', closed_at = now(), updated_by_window_run_id = pg_temp.id('runC')
     where trade_id = pg_temp.id('tMSFT');
    update sgpt.liquidation_item set status = 'closed_confirmed', finished_at = now()
     where liquidation_event_id = pg_temp.id('evC') and item_seq = 1;
    update sgpt.liquidation_event set status = 'completed', finished_at = now()
     where liquidation_event_id = pg_temp.id('evC');
    if (select open_quantity from sgpt.trade_position_v where trade_id = pg_temp.id('tMSFT')) <> 0 then
        raise exception 'T86 FAIL: closed trade shows open quantity';
    end if;
end $$;

-- T87: permanent records — closed trade is final; trades, orders, executions undeletable.
do $$ begin
    begin
        update sgpt.trade set status_detail = 'rewrite', updated_by_window_run_id = pg_temp.id('runC')
         where trade_id = pg_temp.id('tMSFT');
        raise exception 'T87 FAIL: closed trade modified';
    exception when others then perform pg_temp.chk('T87', 'is final', sqlerrm);
    end;
    begin
        delete from sgpt.trade where trade_id = pg_temp.id('tMSFT');
        raise exception 'T87 FAIL: trade deleted';
    exception when others then perform pg_temp.chk('T87', 'cannot be deleted', sqlerrm);
    end;
    begin
        delete from sgpt.broker_order where broker_order_id = pg_temp.id('cMSFT');
        raise exception 'T87 FAIL: order deleted';
    exception when others then perform pg_temp.chk('T87', 'cannot be deleted', sqlerrm);
    end;
    begin
        delete from sgpt.broker_execution where ibkr_exec_id = 'MANUAL.0001';
        raise exception 'T87 FAIL: execution deleted';
    exception when others then perform pg_temp.chk('T87', 'cannot be deleted', sqlerrm);
    end;
end $$;

-- T88: a completed liquidation event is final.
do $$ begin
    begin
        update sgpt.liquidation_event set summary = 'rewrite' where liquidation_event_id = pg_temp.id('evC');
        raise exception 'T88 FAIL: completed liquidation modified';
    exception when others then perform pg_temp.chk('T88', 'is final', sqlerrm);
    end;
end $$;

select pg_temp.end_run(pg_temp.id('runC'));
update sgpt.trading_track set is_halted = false, halted_at = null, halt_reason = null, halted_by_window_run_id = null
 where track_code = 'PRIMARY';

-- =====================================================================
-- Owner Close All (one track): track Halt first, oldest first, one at a time
-- =====================================================================
select pg_temp.new_run('runE', '2026-09-11', null, 'manual_liquidation');
select pg_temp.start_step(pg_temp.id('runE'), 'liquidation');

-- T89: Close All cannot be recorded before that track's Halt is set.
do $$ begin
    begin
        insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
        values (pg_temp.id('runE'), 'PRIMARY', 'liquidation', 'owner_close_all', 'aggressive', 'track');
        raise exception 'T89 FAIL: Close All recorded before track Halt';
    exception when others then perform pg_temp.chk('T89', 'set the track Halt before', sqlerrm);
    end;
end $$;

update sgpt.trading_track set is_halted = true, halted_at = now(), halt_reason = 'Owner Close All',
       halted_by_window_run_id = pg_temp.id('runE'), updated_by = 'owner'
 where track_code = 'PRIMARY';
insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
values (pg_temp.id('runE'), 'PRIMARY', 'liquidation', 'owner_close_all', 'aggressive', 'track');
insert into k select 'evE', liquidation_event_id from sgpt.liquidation_event where window_run_id = pg_temp.id('runE');

-- T90: oldest position first — GOOGL cannot go before the older NVDA.
do $$ begin
    begin
        insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
        values (pg_temp.id('evE'), 1, pg_temp.id('tGOOGL'), now());
        raise exception 'T90 FAIL: newer position liquidated first';
    exception when others then perform pg_temp.chk('T90', 'oldest position first', sqlerrm);
    end;
end $$;

insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
values (pg_temp.id('evE'), 1, pg_temp.id('tNVDA'), now()),
       (pg_temp.id('evE'), 2, pg_temp.id('tGOOGL'), now());

-- T91: never skip ahead — item 2 cannot start while item 1 is not confirmed closed.
do $$ begin
    begin
        update sgpt.liquidation_item set status = 'cancelling_orders', started_at = now()
         where liquidation_event_id = pg_temp.id('evE') and item_seq = 2;
        raise exception 'T91 FAIL: skipped ahead to item 2';
    exception when others then perform pg_temp.chk('T91', 'earlier position is not confirmed closed', sqlerrm);
    end;
end $$;

-- T92: the event cannot complete while items are unfinished.
do $$ begin
    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now()
         where liquidation_event_id = pg_temp.id('evE');
        raise exception 'T92 FAIL: liquidation completed with open items';
    exception when others then perform pg_temp.chk('T92', 'not confirmed closed', sqlerrm);
    end;
end $$;

-- T93: a stopped liquidation records where it stopped, and then accepts no new items.
do $$ begin
    begin
        update sgpt.liquidation_event set status = 'stopped', finished_at = now(), stopped_reason = 'timeout'
         where liquidation_event_id = pg_temp.id('evE');
        raise exception 'T93 FAIL: stop without item position accepted';
    exception when others then perform pg_temp.chk('T93', 'must record the item where it stopped', sqlerrm);
    end;
    update sgpt.liquidation_event set status = 'stopped', finished_at = now(),
           stopped_reason = 'NVDA close not confirmed within timeout', stopped_at_item_seq = 1
     where liquidation_event_id = pg_temp.id('evE');
    begin
        insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
        values (pg_temp.id('evE'), 3, pg_temp.id('tGOOGL'), now());
        raise exception 'T93 FAIL: item added to stopped liquidation';
    exception when others then perform pg_temp.chk('T93', 'cannot add items to a stopped', sqlerrm);
    end;
end $$;

-- T93A: Close All on PRIMARY left the CANDIDATE track un-halted (G3-D12).
do $$ begin
    if (select is_halted from sgpt.trading_track where track_code = 'CANDIDATE')
       or (select is_halted from sgpt.system_state) then
        raise exception 'T93A FAIL: Close All on one track halted something else';
    end if;
end $$;

select pg_temp.end_run(pg_temp.id('runE'));
update sgpt.trading_track set is_halted = false, halted_at = null, halt_reason = null,
       halted_by_window_run_id = null, updated_by = 'owner'
 where track_code = 'PRIMARY';

-- =====================================================================
-- Month end and early close
-- =====================================================================

-- T94: patient pricing is only for month-end attempt one (W2), not W3.
select pg_temp.new_run('runF', '2026-09-30', 'W3', 'month_end_close');
select pg_temp.start_step(pg_temp.id('runF'), 'liquidation');
do $$ begin
    begin
        insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
        values (pg_temp.id('runF'), 'PRIMARY', 'liquidation', 'month_end', 'patient', 'none');
        raise exception 'T94 FAIL: patient pricing accepted at W3';
    exception when others then perform pg_temp.chk('T94', 'patient pricing is only for month-end attempt one', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runF'));

-- T95: no new entries on the last trading day of the month (G3-D4).
select pg_temp.new_run('runG', '2026-09-30', 'W1', 'trading_window');
select pg_temp.start_step(pg_temp.id('runG'), 'bot_d');
do $$ begin
    begin
        insert into sgpt.trade (window_run_id, track_code, broker_account_id, instrument_code, trade_date,
            trade_type, direction, requested_quantity, updated_by_window_run_id)
        select window_run_id, track_code, broker_account_id, 'TSLA', trade_date, 'long_call', 'bullish', 1, window_run_id
          from sgpt.window_run where window_run_id = pg_temp.id('runG');
        raise exception 'T95 FAIL: entry on last trading day accepted';
    exception when others then perform pg_temp.chk('T95', 'last trading day of the month', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runG'));

-- T96: no new entries on an early-close day.
select pg_temp.new_run('runH', '2026-12-24', 'W1', 'trading_window');
select pg_temp.start_step(pg_temp.id('runH'), 'bot_d');
do $$ begin
    begin
        insert into sgpt.trade (window_run_id, track_code, broker_account_id, instrument_code, trade_date,
            trade_type, direction, requested_quantity, updated_by_window_run_id)
        select window_run_id, track_code, broker_account_id, 'TSLA', trade_date, 'long_call', 'bullish', 1, window_run_id
          from sgpt.window_run where window_run_id = pg_temp.id('runH');
        raise exception 'T96 FAIL: entry on early-close day accepted';
    exception when others then perform pg_temp.chk('T96', 'early-close day', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runH'));

-- =====================================================================
-- Corrections C-1, C-2 (part), C-3, C-4 — month-end close across runs
-- =====================================================================
-- October 2026 month end, so the September fixtures above are untouched.
insert into sgpt.market_calendar (trade_date, is_trading_day, market_open_et, market_close_et, is_early_close, source)
values ('2026-10-29', true, '09:30', '16:00', false, 'test'),
       ('2026-10-30', true, '09:30', '16:00', false, 'test');

-- Attempt one: patient, in the W2 slot, on PRIMARY's two open positions.
select pg_temp.new_run('runI', '2026-10-30', 'W2', 'month_end_close');
select pg_temp.start_step(pg_temp.id('runI'), 'liquidation');
insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
values (pg_temp.id('runI'), 'PRIMARY', 'liquidation', 'month_end', 'patient', 'none');
insert into k select 'evI', liquidation_event_id from sgpt.liquidation_event where window_run_id = pg_temp.id('runI');
insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
values (pg_temp.id('evI'), 1, pg_temp.id('tNVDA'), now()),
       (pg_temp.id('evI'), 2, pg_temp.id('tGOOGL'), now());

-- T100 (C-1): the patient attempt places closing orders on every position at
-- once. Item 2 may start while item 1 is still pending. The aggressive rule
-- is unchanged and still proven by T91.
do $$ begin
    begin
        update sgpt.liquidation_item set status = 'cancelling_orders', started_at = now()
         where liquidation_event_id = pg_temp.id('evI') and item_seq = 2;
    exception when others then
        raise exception 'T100 FAIL: patient liquidation still forced one position at a time [%]', sqlerrm;
    end;
    if (select status from sgpt.liquidation_item
         where liquidation_event_id = pg_temp.id('evI') and item_seq = 1) <> 'pending' then
        raise exception 'T100 FAIL: item 1 changed unexpectedly';
    end if;
    update sgpt.liquidation_item set status = 'cancelling_orders', started_at = now()
     where liquidation_event_id = pg_temp.id('evI') and item_seq = 1;
end $$;

-- Cancel NVDA's working exits, then put both trades into closing and send the
-- patient closing orders in the same run.
update sgpt.broker_order set status = 'cancel_requested', last_synced_by_window_run_id = pg_temp.id('runI')
 where trade_id = pg_temp.id('tNVDA') and sgpt.order_is_working(status);
update sgpt.broker_order set status = 'cancelled', finished_at = now(), last_synced_by_window_run_id = pg_temp.id('runI')
 where trade_id = pg_temp.id('tNVDA') and status = 'cancel_requested';
update sgpt.trade set status = 'closing', closing_started_at = now(), close_reason = 'month_end',
       updated_by_window_run_id = pg_temp.id('runI')
 where trade_id in (pg_temp.id('tNVDA'), pg_temp.id('tGOOGL'));
select pg_temp.close_order('cNVDA',  pg_temp.id('tNVDA'),  pg_temp.id('runI'), pg_temp.id('evI'), 1, 1);
select pg_temp.close_order('cGOOGL', pg_temp.id('tGOOGL'), pg_temp.id('runI'), pg_temp.id('evI'), 2, 1);
update sgpt.liquidation_item set status = 'close_submitted'
 where liquidation_event_id = pg_temp.id('evI') and item_seq in (1, 2);

-- The W2 run ends here. Its orders work at IBKR until 2:30 PM; it must not
-- hold the one-run-at-a-time lock until then (H-005 C-1).
update sgpt.window_run_step set status = 'completed', finished_at = now()
 where window_run_id = pg_temp.id('runI') and status = 'running';
update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = pg_temp.id('runI');

-- T102 (C-1): a later run may stop this liquidation or, if it is the month-end
-- checkpoint, finish it. Nothing else may touch it.
-- T104 (C-4): between 1:05 PM and 2:35 PM attempt one is SUPPOSED to be in
-- progress with its run finished. It must not raise a "liquidation stopped"
-- alert before its checkpoint has had a chance to run.
do $$ begin
    if exists (select 1 from sgpt.interrupted_liquidation_v where liquidation_event_id = pg_temp.id('evI')) then
        raise exception 'T104 FAIL: the patient month-end handoff was alerted as an interrupted liquidation';
    end if;
end $$;

select pg_temp.new_run('runL', '2026-10-30', null, 'manual_liquidation');
select pg_temp.start_step(pg_temp.id('runL'), 'liquidation');
do $$ begin
    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now(),
               last_updated_by_window_run_id = pg_temp.id('runL')
         where liquidation_event_id = pg_temp.id('evI');
        raise exception 'T102 FAIL: an unrelated run finished the patient liquidation';
    exception when others then perform pg_temp.chk('T102', 'a later run may only stop it', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runL'));

-- T103 (C-1): the 2:35 PM month_end_checkpoint records what attempt one did.
select pg_temp.new_run('runJ', '2026-10-30', 'V2', 'month_end_checkpoint');
select pg_temp.start_step(pg_temp.id('runJ'), 'liquidation');
do $$ begin
    -- The checkpoint takes the event over.
    update sgpt.liquidation_event set last_updated_by_window_run_id = pg_temp.id('runJ')
     where liquidation_event_id = pg_temp.id('evI');

    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now()
         where liquidation_event_id = pg_temp.id('evI');
        raise exception 'T103 FAIL: completed while both closes were still outstanding';
    exception when others then perform pg_temp.chk('T103', 'not confirmed closed', sqlerrm);
    end;

    -- NVDA filled; GOOGL's mid-price order expired unfilled at 2:30.
    perform pg_temp.sync(pg_temp.id('cNVDA'), pg_temp.id('runJ'), 'filled', 1);
    update sgpt.trade set status = 'closed', closed_at = now(), updated_by_window_run_id = pg_temp.id('runJ')
     where trade_id = pg_temp.id('tNVDA');
    update sgpt.liquidation_item set status = 'closed_confirmed', finished_at = now()
     where liquidation_event_id = pg_temp.id('evI') and item_seq = 1;
    perform pg_temp.sync(pg_temp.id('cGOOGL'), pg_temp.id('runJ'), 'expired', 0);
    update sgpt.liquidation_item set status = 'not_filled', finished_at = now()
     where liquidation_event_id = pg_temp.id('evI') and item_seq = 2;

    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now()
         where liquidation_event_id = pg_temp.id('evI');
        raise exception 'T103 FAIL: completed with a position that never closed';
    exception when others then perform pg_temp.chk('T103', 'not confirmed closed', sqlerrm);
    end;

    -- A later run may finish or stop a liquidation; it may never widen it.
    begin
        insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
        values (pg_temp.id('evI'), 3, pg_temp.id('tGOOGL'), now());
        raise exception 'T103 FAIL: the checkpoint added a position to attempt one';
    exception when others then perform pg_temp.chk('T103', 'may only be added by the run that started', sqlerrm);
    end;

    -- Partial is the correct outcome: attempt one worked as designed.
    update sgpt.liquidation_event set status = 'partial', finished_at = now(),
           summary = 'Attempt one: NVDA closed, GOOGL did not fill at mid'
     where liquidation_event_id = pg_temp.id('evI');
    if (select status from sgpt.liquidation_event where liquidation_event_id = pg_temp.id('evI')) <> 'partial' then
        raise exception 'T103 FAIL: patient attempt did not end partial';
    end if;
end $$;
update sgpt.window_run_step set status = 'completed', finished_at = now()
 where window_run_id = pg_temp.id('runJ') and status = 'running';
update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = pg_temp.id('runJ');

-- T105 (C-1): partial and not_filled belong to the patient attempt only.
-- Attempt two, in the W3 slot, is aggressive and gets neither.
select pg_temp.new_run('runN', '2026-10-30', 'W3', 'month_end_close');
select pg_temp.start_step(pg_temp.id('runN'), 'liquidation');
insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
values (pg_temp.id('runN'), 'PRIMARY', 'liquidation', 'month_end', 'aggressive', 'none');
insert into k select 'evN', liquidation_event_id from sgpt.liquidation_event where window_run_id = pg_temp.id('runN');
insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
values (pg_temp.id('evN'), 1, pg_temp.id('tGOOGL'), now());
update sgpt.liquidation_item set status = 'cancelling_orders', started_at = now()
 where liquidation_event_id = pg_temp.id('evN') and item_seq = 1;
select pg_temp.close_order('cGOOGL2', pg_temp.id('tGOOGL'), pg_temp.id('runN'), pg_temp.id('evN'), 1, 1);
update sgpt.liquidation_item set status = 'close_submitted'
 where liquidation_event_id = pg_temp.id('evN') and item_seq = 1;
do $$ begin
    begin
        update sgpt.liquidation_item set status = 'not_filled', finished_at = now()
         where liquidation_event_id = pg_temp.id('evN') and item_seq = 1;
        raise exception 'T105 FAIL: not_filled accepted on an aggressive liquidation';
    exception when others then perform pg_temp.chk('T105', 'patient month-end attempt only', sqlerrm);
    end;
    begin
        update sgpt.liquidation_event set status = 'partial', finished_at = now()
         where liquidation_event_id = pg_temp.id('evN');
        raise exception 'T105 FAIL: partial accepted on an aggressive liquidation';
    exception when others then perform pg_temp.chk('T105', 'partial belongs to the patient month-end attempt only', sqlerrm);
    end;
end $$;

-- T106 (C-2, part): a liquidation that closed nothing cannot be recorded as
-- successful by accident, and the flag cannot be used where positions exist.
do $$ begin
    perform pg_temp.sync(pg_temp.id('cGOOGL2'), pg_temp.id('runN'), 'filled', 1);
    update sgpt.trade set status = 'closed', closed_at = now(), updated_by_window_run_id = pg_temp.id('runN')
     where trade_id = pg_temp.id('tGOOGL');
    update sgpt.liquidation_item set status = 'closed_confirmed', finished_at = now()
     where liquidation_event_id = pg_temp.id('evN') and item_seq = 1;
    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now(),
               no_positions_to_close = true
         where liquidation_event_id = pg_temp.id('evN');
        raise exception 'T106 FAIL: nothing-to-close recorded on a liquidation holding a position';
    exception when others then perform pg_temp.chk('T106', 'cannot be set on a liquidation holding', sqlerrm);
    end;
    update sgpt.liquidation_event set status = 'completed', finished_at = now()
     where liquidation_event_id = pg_temp.id('evN');
end $$;
update sgpt.window_run_step set status = 'completed', finished_at = now()
 where window_run_id = pg_temp.id('runN') and status = 'running';
update sgpt.window_run set status = 'completed', finished_at = now() where window_run_id = pg_temp.id('runN');

-- T101 (C-3): a month-end run whose Reconciliation step triggered a liquidation
-- must still be able to record its month-end liquidation.
select pg_temp.new_run('runM', '2026-10-30', 'W2', 'month_end_close', 'CANDIDATE');
select pg_temp.start_step(pg_temp.id('runM'), 'reconciliation');
insert into sgpt.reconciliation_check (window_run_id, check_seq, result, mismatch_count, expected_positions, actual_positions)
values (pg_temp.id('runM'), 1, 'mismatch', 1, '[{"MSFT": 1}]', '[]'),
       (pg_temp.id('runM'), 2, 'mismatch', 1, '[{"MSFT": 1}]', '[]');
insert into sgpt.reconciliation_mismatch (window_run_id, check_seq, symbol, instrument_code, trade_id, expected_detail, actual_detail)
values (pg_temp.id('runM'), 1, 'MSFT', 'MSFT', pg_temp.id('tMSFT_C'), '{"qty": 1}', '{"qty": 0}'),
       (pg_temp.id('runM'), 2, 'MSFT', 'MSFT', pg_temp.id('tMSFT_C'), '{"qty": 1}', '{"qty": 0}');
update sgpt.trading_track set is_halted = true, halted_at = now(),
       halt_reason = 'Reconciliation mismatch confirmed on MSFT', halted_by_window_run_id = pg_temp.id('runM')
 where track_code = 'CANDIDATE';
insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope, reconciliation_check_seq)
values (pg_temp.id('runM'), 'CANDIDATE', 'reconciliation', 'reconciliation_single', 'aggressive', 'track', 2);
insert into k select 'evM1', liquidation_event_id from sgpt.liquidation_event
 where window_run_id = pg_temp.id('runM') and step_code = 'reconciliation';
do $$ begin
    begin
        insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope, reconciliation_check_seq)
        values (pg_temp.id('runM'), 'CANDIDATE', 'reconciliation', 'reconciliation_single', 'aggressive', 'track', 2);
        raise exception 'T101 FAIL: two liquidation events accepted in one step';
    exception when others then perform pg_temp.chk('T101', 'liquidation_event_one_per_step_uq', sqlerrm);
    end;
end $$;
update sgpt.window_run_step set status = 'completed', finished_at = now()
 where window_run_id = pg_temp.id('runM') and step_code = 'reconciliation';
select pg_temp.start_step(pg_temp.id('runM'), 'liquidation');
do $$ begin
    begin
        insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
        values (pg_temp.id('runM'), 'CANDIDATE', 'liquidation', 'month_end', 'aggressive', 'none');
    exception when others then
        raise exception 'T101 FAIL: month-end close could not record its liquidation after a reconciliation liquidation in the same run [%]', sqlerrm;
    end;
end $$;
insert into k select 'evM2', liquidation_event_id from sgpt.liquidation_event
 where window_run_id = pg_temp.id('runM') and step_code = 'liquidation';
do $$ begin
    if (select count(*) from sgpt.liquidation_event where window_run_id = pg_temp.id('runM')) <> 2 then
        raise exception 'T101 FAIL: month-end close could not record its liquidation after a reconciliation failure';
    end if;
    -- T106 continued: a track-wide liquidation cannot be called successful
    -- while the track still holds an active trade. This is the hole that let
    -- an empty liquidation event be marked completed with a position open.
    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now(),
               no_positions_to_close = true
         where liquidation_event_id = pg_temp.id('evM2');
        raise exception 'T106 FAIL: liquidation completed while an active trade remained on the track';
    exception when others then perform pg_temp.chk('T106', 'active trade(s) still open on track', sqlerrm);
    end;
end $$;
-- The run is abandoned partway through, leaving both events in progress.
select pg_temp.end_run(pg_temp.id('runM'));

-- T104 (C-4): an interrupted liquidation is visible and can be recorded as
-- stopped by a later run on the same track. Before this correction it stayed
-- in progress permanently, because only the owning run could update it.
do $$ begin
    if (select count(*) from sgpt.interrupted_liquidation_v
         where liquidation_event_id in (pg_temp.id('evM1'), pg_temp.id('evM2'))) <> 2 then
        raise exception 'T104 FAIL: interrupted liquidations not surfaced for alerting';
    end if;
    if exists (select 1 from sgpt.interrupted_liquidation_v where liquidation_event_id = pg_temp.id('evI')) then
        raise exception 'T104 FAIL: a finished patient attempt was flagged as interrupted';
    end if;
end $$;

select pg_temp.new_run('runQ', '2026-10-30', null, 'manual_liquidation', 'CANDIDATE');
select pg_temp.start_step(pg_temp.id('runQ'), 'liquidation');
do $$ begin
    update sgpt.liquidation_event set status = 'stopped', finished_at = now(),
           stopped_reason = 'Run abandoned before the liquidation finished',
           last_updated_by_window_run_id = pg_temp.id('runQ')
     where liquidation_event_id = pg_temp.id('evM2');
    if (select status from sgpt.liquidation_event where liquidation_event_id = pg_temp.id('evM2')) <> 'stopped' then
        raise exception 'T104 FAIL: interrupted liquidation could not be stopped';
    end if;
end $$;
select pg_temp.end_run(pg_temp.id('runQ'));

-- T104 continued: a run on another track may not touch it.
-- (The sleep is a test artifact: an owner-triggered run's label is stamped to
-- the second, so two manual runs on one track in the same second collide.
-- In operation that collision is a feature — it stops a double-click from
-- creating two liquidation runs.)
select pg_sleep(1);
select pg_temp.new_run('runR', '2026-10-30', null, 'manual_liquidation');
select pg_temp.start_step(pg_temp.id('runR'), 'liquidation');
do $$ begin
    begin
        update sgpt.liquidation_event set status = 'stopped', finished_at = now(),
               stopped_reason = 'wrong track', last_updated_by_window_run_id = pg_temp.id('runR')
         where liquidation_event_id = pg_temp.id('evM1');
        raise exception 'T104 FAIL: a PRIMARY run stopped a CANDIDATE liquidation';
    exception when others then perform pg_temp.chk('T104', 'only a run on track CANDIDATE', sqlerrm);
    end;
end $$;

-- T106 continued: an owner Close All that finds nothing to close. PRIMARY is
-- flat now, so the event legitimately has no positions — and must say so.
update sgpt.trading_track set is_halted = true, halted_at = now(), halt_reason = 'Owner Close All',
       halted_by_window_run_id = pg_temp.id('runR'), updated_by = 'owner'
 where track_code = 'PRIMARY';
insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope)
values (pg_temp.id('runR'), 'PRIMARY', 'liquidation', 'owner_close_all', 'aggressive', 'track');
insert into k select 'evR', liquidation_event_id from sgpt.liquidation_event where window_run_id = pg_temp.id('runR');
do $$ begin
    begin
        update sgpt.liquidation_event set status = 'completed', finished_at = now()
         where liquidation_event_id = pg_temp.id('evR');
        raise exception 'T106 FAIL: empty liquidation completed silently';
    exception when others then perform pg_temp.chk('T106', 'unless it records that there was nothing to close', sqlerrm);
    end;
    update sgpt.liquidation_event set status = 'completed', finished_at = now(),
           no_positions_to_close = true, summary = 'Close All: no open positions on PRIMARY'
     where liquidation_event_id = pg_temp.id('evR');
end $$;
select pg_temp.end_run(pg_temp.id('runR'));
update sgpt.trading_track set is_halted = false, halted_at = null, halt_reason = null,
       halted_by_window_run_id = null, updated_by = 'owner'
 where track_code in ('PRIMARY', 'CANDIDATE');

-- =====================================================================
-- Correction C-2 — unmatched positions and owner resolution
-- =====================================================================
-- A bull call spread on PRIMARY. Its short leg is assigned early, leaving
-- stock and a remaining long call that match no recorded trade's legs.
insert into sgpt.market_calendar (trade_date, is_trading_day, market_open_et, market_close_et, is_early_close, source)
values ('2026-09-09', true, '09:30', '16:00', false, 'test');
select pg_temp.new_run('runS', '2026-09-09', 'W1', 'trading_window');
select pg_temp.start_step(pg_temp.id('runS'), 'bot_c');
select pg_temp.proposal(pg_temp.id('runS'), 'TSLA', 'bull_call_spread');
select pg_temp.start_step(pg_temp.id('runS'), 'bot_d');
select pg_temp.verify(pg_temp.id('runS'), 'TSLA');
do $$
declare v_t uuid;
begin
    v_t := pg_temp.new_trade('tTSLA', pg_temp.id('runS'), 'TSLA', 2);
    perform pg_temp.add_legs(v_t);
    perform pg_temp.entry('eTSLA', v_t);
    perform pg_temp.sync(pg_temp.id('eTSLA'), pg_temp.id('runS'), 'filled', 2);
    update sgpt.trade set status = 'open', opened_at = now(), updated_by_window_run_id = pg_temp.id('runS')
     where trade_id = v_t;
end $$;
select pg_temp.end_run(pg_temp.id('runS'));

select pg_temp.new_run('runT', '2026-09-09', 'W2', 'trading_window');
select pg_temp.start_step(pg_temp.id('runT'), 'reconciliation');
insert into sgpt.reconciliation_check (window_run_id, check_seq, result, mismatch_count, expected_positions, actual_positions)
values (pg_temp.id('runT'), 1, 'mismatch', 1, '[{"TSLA": "2 spreads"}]', '[{"TSLA": "200 shares short, 2 long calls"}]'),
       (pg_temp.id('runT'), 2, 'mismatch', 1, '[{"TSLA": "2 spreads"}]', '[{"TSLA": "200 shares short, 2 long calls"}]');
insert into sgpt.reconciliation_mismatch (window_run_id, check_seq, symbol, instrument_code, trade_id, expected_detail, actual_detail)
values (pg_temp.id('runT'), 1, 'TSLA', 'TSLA', pg_temp.id('tTSLA'), '{"spreads": 2}', '{"shares": -200}'),
       (pg_temp.id('runT'), 2, 'TSLA', 'TSLA', pg_temp.id('tTSLA'), '{"spreads": 2}', '{"shares": -200}');

-- T107: Halt first — an unmatched position cannot be recorded before the
-- track Halt is on, the same rule the liquidation records follow.
do $$ begin
    begin
        insert into sgpt.unmatched_position (window_run_id, track_code, broker_account_id,
            reconciliation_check_seq, symbol, sec_type, ibkr_quantity,
            expected_detail, actual_detail, suspected_trade_id, suspected_cause)
        select pg_temp.id('runT'), 'PRIMARY', broker_account_id, 2, 'TSLA', 'STK', -200,
               '{"spreads": 2}', '{"shares": -200}', pg_temp.id('tTSLA'), 'early_assignment'
          from sgpt.window_run where window_run_id = pg_temp.id('runT');
        raise exception 'T107 FAIL: unmatched position recorded before the track Halt';
    exception when others then perform pg_temp.chk('T107', 'set the track Halt before recording an unmatched position', sqlerrm);
    end;
end $$;

update sgpt.trading_track set is_halted = true, halted_at = now(),
       halt_reason = 'Unmatched TSLA position: short stock from early assignment',
       halted_by_window_run_id = pg_temp.id('runT')
 where track_code = 'PRIMARY';
insert into sgpt.unmatched_position (window_run_id, track_code, broker_account_id,
    reconciliation_check_seq, symbol, sec_type, ibkr_quantity,
    expected_detail, actual_detail, suspected_trade_id, suspected_cause)
select pg_temp.id('runT'), 'PRIMARY', broker_account_id, 2, 'TSLA', 'STK', -200,
       '{"spreads": 2}', '{"shares": -200}', pg_temp.id('tTSLA'), 'early_assignment'
  from sgpt.window_run where window_run_id = pg_temp.id('runT');
insert into k select 'upTSLA', unmatched_position_id from sgpt.unmatched_position
 where window_run_id = pg_temp.id('runT');

-- T108: the system never closes a position it cannot account for. The
-- liquidation may be recorded, but it may not cover the affected trade.
do $$ begin
    insert into sgpt.liquidation_event (window_run_id, track_code, step_code, trigger_type, urgency, halt_scope, reconciliation_check_seq)
    values (pg_temp.id('runT'), 'PRIMARY', 'reconciliation', 'reconciliation_single', 'aggressive', 'track', 2);
    insert into k select 'evT', liquidation_event_id from sgpt.liquidation_event where window_run_id = pg_temp.id('runT');
    begin
        insert into sgpt.liquidation_item (liquidation_event_id, item_seq, trade_id, trade_sort_at)
        values (pg_temp.id('evT'), 1, pg_temp.id('tTSLA'), now());
        raise exception 'T108 FAIL: the system liquidated a position it could not account for';
    exception when others then perform pg_temp.chk('T108', 'the owner must resolve it, the system does not close it', sqlerrm);
    end;
end $$;

-- T109: the Halt cannot be released while the unmatched position stands.
do $$ begin
    begin
        update sgpt.trading_track set is_halted = false, halted_at = null, halt_reason = null,
               halted_by_window_run_id = null, updated_by = 'owner'
         where track_code = 'PRIMARY';
        raise exception 'T109 FAIL: Halt released with an unresolved unmatched position';
    exception when others then perform pg_temp.chk('T109', 'unmatched position(s) still unresolved', sqlerrm);
    end;
end $$;

-- T110: an unmatched position cannot be resolved from an ordinary run.
do $$ begin
    begin
        update sgpt.unmatched_position
           set status = 'resolved', resolved_at = now(),
               resolved_by_window_run_id = pg_temp.id('runT'),
               resolution_action = 'closed_in_ibkr', owner_note = 'wrong kind of run'
         where unmatched_position_id = pg_temp.id('upTSLA');
        raise exception 'T110 FAIL: unmatched position resolved by a trading window run';
    exception when others then perform pg_temp.chk('T110', 'resolved by an owner_resolution run', sqlerrm);
    end;
    begin
        insert into sgpt.trade_quantity_adjustment (trade_id, unmatched_position_id, quantity, reason,
            owner_note, recorded_by_window_run_id)
        values (pg_temp.id('tTSLA'), pg_temp.id('upTSLA'), 1, 'early_assignment',
                'wrong kind of run', pg_temp.id('runT'));
        raise exception 'T110 FAIL: quantity written off by a trading window run';
    exception when others then perform pg_temp.chk('T110', 'may only be recorded by an owner_resolution run', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runT'));

-- The owner buys back the short stock in IBKR and records what happened.
select pg_temp.new_run('runU', '2026-09-09', null, 'owner_resolution');
select pg_temp.start_step(pg_temp.id('runU'), 'resolution');

-- T111: an owner_resolution close needs the owner-attested quantity.
do $$ begin
    begin
        update sgpt.trade set status = 'closed', closed_at = now(), close_reason = 'owner_resolution',
               updated_by_window_run_id = pg_temp.id('runU')
         where trade_id = pg_temp.id('tTSLA');
        raise exception 'T111 FAIL: trade closed by attestation with nothing attested';
    exception when others then perform pg_temp.chk('T111', 'needs the owner-attested quantity adjustment', sqlerrm);
    end;
end $$;

-- T112: an adjustment can never exceed what the trade actually holds, so it
-- cannot invent a position or create a short.
do $$ begin
    begin
        insert into sgpt.trade_quantity_adjustment (trade_id, unmatched_position_id, quantity, reason,
            owner_note, recorded_by_window_run_id)
        values (pg_temp.id('tTSLA'), pg_temp.id('upTSLA'), 3, 'early_assignment',
                'too much', pg_temp.id('runU'));
        raise exception 'T112 FAIL: adjustment larger than the open quantity accepted';
    exception when others then perform pg_temp.chk('T112', 'exceeds the open quantity', sqlerrm);
    end;
end $$;

-- T113: open quantity is still computed. One spread written off leaves one.
do $$
declare q record;
begin
    insert into sgpt.trade_quantity_adjustment (trade_id, unmatched_position_id, quantity, reason,
        owner_note, recorded_by_window_run_id)
    values (pg_temp.id('tTSLA'), pg_temp.id('upTSLA'), 1, 'early_assignment',
            'One short call assigned overnight; bought the stock back at the open.',
            pg_temp.id('runU'));
    select * into q from sgpt.trade_position_v where trade_id = pg_temp.id('tTSLA');
    if q.adjusted_quantity <> 1 or q.open_quantity <> 1 then
        raise exception 'T113 FAIL: expected 1 adjusted and 1 open, got % and %',
            q.adjusted_quantity, q.open_quantity;
    end if;
    begin
        update sgpt.trade set status = 'closed', closed_at = now(), close_reason = 'owner_resolution',
               updated_by_window_run_id = pg_temp.id('runU')
         where trade_id = pg_temp.id('tTSLA');
        raise exception 'T113 FAIL: trade closed with quantity still open';
    exception when others then perform pg_temp.chk('T113', 'closed requires zero open quantity', sqlerrm);
    end;
end $$;

-- T114: the trade reaches zero the ordinary way and closes by the normal path.
do $$
declare q record;
begin
    insert into sgpt.trade_quantity_adjustment (trade_id, unmatched_position_id, quantity, reason,
        owner_note, recorded_by_window_run_id)
    values (pg_temp.id('tTSLA'), pg_temp.id('upTSLA'), 1, 'early_assignment',
            'Second short call assigned; closed the remaining long call manually.',
            pg_temp.id('runU'));
    update sgpt.trade set status = 'closed', closed_at = now(), close_reason = 'owner_resolution',
           updated_by_window_run_id = pg_temp.id('runU')
     where trade_id = pg_temp.id('tTSLA');
    select * into q from sgpt.trade_position_v where trade_id = pg_temp.id('tTSLA');
    if q.open_quantity <> 0 or q.status <> 'closed' then
        raise exception 'T114 FAIL: trade did not close through the normal path';
    end if;
end $$;

-- T115: the resolution is recorded, and only then can the Halt be released.
do $$ begin
    update sgpt.unmatched_position
       set status = 'resolved', resolved_at = now(),
           resolved_by_window_run_id = pg_temp.id('runU'),
           resolution_action = 'closed_in_ibkr',
           owner_note = 'Bought back 200 TSLA shares and closed the remaining long calls in IBKR.'
     where unmatched_position_id = pg_temp.id('upTSLA');
    begin
        update sgpt.unmatched_position set owner_note = 'rewrite'
         where unmatched_position_id = pg_temp.id('upTSLA');
        raise exception 'T115 FAIL: a resolved unmatched position was rewritten';
    exception when others then perform pg_temp.chk('T115', 'already resolved and cannot be changed', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runU'));

do $$ begin
    begin
        update sgpt.trading_track set is_halted = false, halted_at = null, halt_reason = null,
               halted_by_window_run_id = null, updated_by = 'owner'
         where track_code = 'PRIMARY';
    exception when others then
        raise exception 'T115 FAIL: Halt still blocked after the resolution was recorded [%]', sqlerrm;
    end;
end $$;

-- T116: thesis-invalidation closes are rejected until that path is designed
-- (V13-D1). Requirements v1.3 and H-005 both say the database already did
-- this; until this draft it did not.
select pg_temp.new_run('runV', '2026-09-09', null, 'manual_liquidation', 'CANDIDATE');
select pg_temp.start_step(pg_temp.id('runV'), 'liquidation');
do $$ begin
    begin
        update sgpt.trade set status = 'closing', closing_started_at = now(),
               close_reason = 'thesis_invalidation', updated_by_window_run_id = pg_temp.id('runV')
         where trade_id = pg_temp.id('tMSFT_C');
        raise exception 'T116 FAIL: thesis-invalidation close accepted';
    exception when others then perform pg_temp.chk('T116', 'thesis-invalidation closes are not built yet', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runV'));

select 'G3 TESTS PASSED' as result;
