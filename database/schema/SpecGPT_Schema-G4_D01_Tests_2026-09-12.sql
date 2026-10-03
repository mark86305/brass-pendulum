-- =====================================================================
-- SpeculativeGPT — Group 4 invariant tests (Draft G4-D1)
-- Run against a disposable database AFTER, in order:
--   G1-D4 schema, G1-D4 tests, G2-D2 schema, G2-D2 tests,
--   G3-D2 schema, G3-D2 tests, G4-D1 schema.
-- Every rejection test also checks the error text, so a test cannot pass
-- because some unrelated rule happened to fire.
-- Prints "G4 TESTS PASSED" at the end.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- Test helpers (this file runs in its own session)
-- ---------------------------------------------------------------------
create temp table k4 (name text primary key, id uuid not null);
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k4 where name = p $$;

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
           'g4testsha', '10.37.1', '10.37.2'
    from sgpt.trading_track t
    join sgpt.broker_account b using (broker_account_id)
    cross join sgpt.system_state ss
    left join sgpt.schedule_slot sl on sl.slot_code = p_slot
    where t.track_code = p_track
    returning window_run_id into v;
    insert into k4 values (p_name, v);
    return v;
end $$;

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
    update sgpt.window_run set status = 'abandoned', finished_at = now(), status_detail = 'G4 test cleanup'
     where window_run_id = p_run and status = 'running';
    update sgpt.window_run_step set status = 'abandoned', finished_at = now()
     where window_run_id = p_run and status = 'running';
end $$;

create function pg_temp.snapshot(p_run uuid, p_netliq numeric) returns void
language plpgsql as $$
begin
    insert into sgpt.account_value_snapshot (window_run_id, track_code, broker_account_id,
        as_of, net_liquidation_value, total_cash, position_market_value)
    select window_run_id, track_code, broker_account_id, now(), p_netliq, p_netliq, 0
      from sgpt.window_run where window_run_id = p_run;
end $$;

-- Fixture: a fresh trading day for Group 4's runs.
insert into sgpt.market_calendar (trade_date, is_trading_day, market_open_et, market_close_et, is_early_close, source)
values ('2026-09-08', true, '09:30', '16:00', false, 'test');

-- =====================================================================
-- account_value_snapshot
-- =====================================================================
select pg_temp.new_run('runA4', '2026-09-08', 'W1', 'trading_window');

-- T117: account value is recorded by Broker Sync and by nothing else. The
-- step that is about to size a position may not also assert what the
-- account is worth.
select pg_temp.start_step(pg_temp.id('runA4'), 'bot_c');
do $$ begin
    begin
        perform pg_temp.snapshot(pg_temp.id('runA4'), 15000);
        raise exception 'T117 FAIL: account value recorded outside Broker Sync';
    exception when others then perform pg_temp.chk('T117', 'allowed only while step {broker_sync} is running', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runA4'));

select pg_temp.new_run('runB4', '2026-09-08', 'W2', 'trading_window');
select pg_temp.start_step(pg_temp.id('runB4'), 'broker_sync');

-- T118: a snapshot cannot be dated in the future.
do $$ begin
    begin
        insert into sgpt.account_value_snapshot (window_run_id, track_code, broker_account_id,
            as_of, net_liquidation_value, total_cash, position_market_value)
        select window_run_id, track_code, broker_account_id, now() + interval '2 hours', 15000, 15000, 0
          from sgpt.window_run where window_run_id = pg_temp.id('runB4');
        raise exception 'T118 FAIL: future-dated account value accepted';
    exception when others then perform pg_temp.chk('T118', 'dated in the future', sqlerrm);
    end;
end $$;

-- T119: the snapshot is written once and is then a permanent record.
do $$ begin
    perform pg_temp.snapshot(pg_temp.id('runB4'), 15000);
    begin
        update sgpt.account_value_snapshot set net_liquidation_value = 99000
         where window_run_id = pg_temp.id('runB4');
        raise exception 'T119 FAIL: account value rewritten';
    exception when others then perform pg_temp.chk('T119', 'write-once', sqlerrm);
    end;
    begin
        delete from sgpt.account_value_snapshot where window_run_id = pg_temp.id('runB4');
        raise exception 'T119 FAIL: account value deleted';
    exception when others then perform pg_temp.chk('T119', 'write-once', sqlerrm);
    end;
    -- One Broker Sync, one snapshot per account.
    begin
        perform pg_temp.snapshot(pg_temp.id('runB4'), 15100);
        raise exception 'T119 FAIL: two account values recorded by one run';
    exception when others then perform pg_temp.chk('T119', 'account_value_snapshot_one_per_run_uq', sqlerrm);
    end;
end $$;

-- =====================================================================
-- capital_baseline
-- =====================================================================

-- T120: the levels are a band, not a line, and neither may sit above the
-- value they were derived from.
do $$ begin
    begin
        insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
            engage_level, release_level, mode, owner_note)
        values ('PRIMARY', date_trunc('month', current_date)::date, 15000, 13000, 12000,
                'observing', 'engage above release');
        raise exception 'T120 FAIL: engage level above release level accepted';
    exception when others then perform pg_temp.chk('T120', 'capital_baseline_band_chk', sqlerrm);
    end;
    begin
        insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
            engage_level, release_level, mode, owner_note)
        values ('PRIMARY', date_trunc('month', current_date)::date, 15000, 14000, 16000,
                'observing', 'release above baseline');
        raise exception 'T120 FAIL: release level above the baseline accepted';
    exception when others then perform pg_temp.chk('T120', 'capital_baseline_ceiling_chk', sqlerrm);
    end;
    begin
        insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
            engage_level, release_level, mode, owner_note)
        values ('PRIMARY', date_trunc('month', current_date)::date + 5, 15000, 10500, 12750,
                'observing', 'mid-month');
        raise exception 'T120 FAIL: baseline effective mid-month accepted';
    exception when others then perform pg_temp.chk('T120', 'capital_baseline_month_chk', sqlerrm);
    end;
end $$;

-- T121: the first baseline for a track may start this month. The levels are
-- dollars; the percentage is computed for display only.
do $$
declare v record;
begin
    insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
        engage_level, release_level, mode, owner_note)
    values ('PRIMARY', date_trunc('month', current_date)::date, 15000, 10500, 12750,
            'observing', 'Opening band, set wide to watch normal movement first.');
    select * into v from sgpt.current_capital_baseline_v where track_code = 'PRIMARY';
    if v.engage_level <> 10500 or v.mode <> 'observing' then
        raise exception 'T121 FAIL: current baseline not reported correctly';
    end if;
    if v.implied_engage_drawdown_pct <> 30.00 then
        raise exception 'T121 FAIL: implied drawdown should be 30.00, got %', v.implied_engage_drawdown_pct;
    end if;
end $$;

-- T122: a change waits for the next monthly reset, so each month stays a
-- clean comparison period.
do $$ begin
    begin
        insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
            engage_level, release_level, mode, owner_note)
        values ('PRIMARY', date_trunc('month', current_date)::date, 20000, 17000, 18000,
                'active', 'ratchet up mid-month');
        raise exception 'T122 FAIL: baseline changed during a month already in progress';
    exception when others then perform pg_temp.chk('T122', 'takes effect at the next monthly reset', sqlerrm);
    end;
    begin
        insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
            engage_level, release_level, mode, owner_note)
        values ('PRIMARY', (date_trunc('month', current_date) - interval '1 month')::date,
                12000, 8000, 10000, 'active', 'backdated');
        raise exception 'T122 FAIL: backdated baseline accepted';
    exception when others then perform pg_temp.chk('T122', 'cannot be backdated', sqlerrm);
    end;
end $$;

-- T123: a baseline in force is frozen; a pending one may still be corrected.
do $$ begin
    begin
        update sgpt.capital_baseline set engage_level = 9000, owner_note = 'rewrite history'
         where track_code = 'PRIMARY' and effective_month = date_trunc('month', current_date)::date;
        raise exception 'T123 FAIL: a baseline in force was changed';
    exception when others then perform pg_temp.chk('T123', 'is in force and cannot be changed', sqlerrm);
    end;

    -- The owner ratchets up for next month, then corrects it before it starts.
    insert into sgpt.capital_baseline (track_code, effective_month, baseline_value,
        engage_level, release_level, mode, owner_note)
    values ('PRIMARY', (date_trunc('month', current_date) + interval '1 month')::date,
            22000, 15400, 18700, 'active',
            'Account doubled; locking in. Band now a real limit, not an observation.');
    update sgpt.capital_baseline set engage_level = 16000, owner_note = 'Tightened after the month-end review.'
     where track_code = 'PRIMARY'
       and effective_month = (date_trunc('month', current_date) + interval '1 month')::date;
    if (select engage_level from sgpt.capital_baseline
         where track_code = 'PRIMARY'
           and effective_month = (date_trunc('month', current_date) + interval '1 month')::date) <> 16000 then
        raise exception 'T123 FAIL: pending baseline could not be corrected';
    end if;
    begin
        delete from sgpt.capital_baseline where track_code = 'PRIMARY';
        raise exception 'T123 FAIL: baseline deleted';
    exception when others then perform pg_temp.chk('T123', 'cannot be deleted', sqlerrm);
    end;
end $$;

-- T124: a pending baseline does not govern anything until its month starts.
do $$ begin
    if (select effective_month from sgpt.current_capital_baseline_v where track_code = 'PRIMARY')
       <> date_trunc('month', current_date)::date then
        raise exception 'T124 FAIL: next month''s baseline is already governing this month';
    end if;
end $$;

-- =====================================================================
-- external_cash_flow
-- =====================================================================

-- T125: money that arrives late in the month counts from the next one, so
-- it does not move position sizing or the baseline for those few days.
do $$
declare v date;
begin
    insert into sgpt.external_cash_flow (track_code, broker_account_id, direction, amount,
        settled_on, owner_note)
    select 'PRIMARY', broker_account_id, 'deposit', 5000, '2026-09-28',
           'Funded on the 28th to go live on the 1st.'
      from sgpt.trading_track where track_code = 'PRIMARY';
    select effective_month into v from sgpt.external_cash_flow
     where settled_on = '2026-09-28' and track_code = 'PRIMARY';
    if v <> '2026-10-01' then
        raise exception 'T125 FAIL: late-month deposit should count from 2026-10-01, got %', v;
    end if;

    insert into sgpt.external_cash_flow (track_code, broker_account_id, direction, amount,
        settled_on, owner_note)
    select 'PRIMARY', broker_account_id, 'withdrawal', 1000, '2026-09-10', 'Mid-month draw.'
      from sgpt.trading_track where track_code = 'PRIMARY';
    select effective_month into v from sgpt.external_cash_flow
     where settled_on = '2026-09-10' and track_code = 'PRIMARY';
    if v <> '2026-09-01' then
        raise exception 'T125 FAIL: mid-month flow should count from its own month, got %', v;
    end if;
end $$;

-- T126: money cannot count from before it arrived, and the amount is always
-- positive so a negative deposit cannot be recorded by accident.
do $$ begin
    begin
        insert into sgpt.external_cash_flow (track_code, broker_account_id, direction, amount,
            settled_on, effective_month, owner_note)
        select 'PRIMARY', broker_account_id, 'deposit', 5000, '2026-09-28', '2026-08-01', 'backdated'
          from sgpt.trading_track where track_code = 'PRIMARY';
        raise exception 'T126 FAIL: cash flow effective before it settled';
    exception when others then perform pg_temp.chk('T126', 'external_cash_flow_effective_chk', sqlerrm);
    end;
    begin
        insert into sgpt.external_cash_flow (track_code, broker_account_id, direction, amount,
            settled_on, owner_note)
        select 'PRIMARY', broker_account_id, 'deposit', -5000, '2026-09-28', 'negative deposit'
          from sgpt.trading_track where track_code = 'PRIMARY';
        raise exception 'T126 FAIL: negative amount accepted';
    exception when others then perform pg_temp.chk('T126', 'external_cash_flow_amount_check', sqlerrm);
    end;
end $$;

-- T127: a cash flow is a permanent record, and its account must belong to
-- the track it is recorded against.
do $$ begin
    begin
        update sgpt.external_cash_flow set amount = 1 where settled_on = '2026-09-10';
        raise exception 'T127 FAIL: cash flow amended';
    exception when others then perform pg_temp.chk('T127', 'write-once', sqlerrm);
    end;
    begin
        delete from sgpt.external_cash_flow where settled_on = '2026-09-10';
        raise exception 'T127 FAIL: cash flow deleted';
    exception when others then perform pg_temp.chk('T127', 'write-once', sqlerrm);
    end;
    begin
        insert into sgpt.external_cash_flow (track_code, broker_account_id, direction, amount,
            settled_on, owner_note)
        select 'PRIMARY', broker_account_id, 'deposit', 5000, '2026-09-08', 'wrong account'
          from sgpt.trading_track where track_code = 'CANDIDATE';
        raise exception 'T127 FAIL: cash flow recorded against another track''s account';
    exception when others then perform pg_temp.chk('T127', 'does not belong to track', sqlerrm);
    end;
end $$;

select pg_temp.end_run(pg_temp.id('runB4'));

-- =====================================================================
-- strategy_revision, revision_parameter, and the audit logs
-- =====================================================================

-- T128: the revision identifier format is enforced, so an identifier
-- always sorts chronologically and says which subsystem changed.
do $$ begin
    begin
        insert into sgpt.strategy_revision (strategy_revision_id, description, trading_affecting)
        values ('rev-7', 'freeform identifier', true);
        raise exception 'T128 FAIL: malformed revision identifier accepted';
    exception when others then perform pg_temp.chk('T128', 'strategy_revision_strategy_revision_id_check', sqlerrm);
    end;
    begin
        insert into sgpt.strategy_revision (strategy_revision_id, description, trading_affecting)
        values ('R-20260912-WIDGET-01', 'unknown subsystem', true);
        raise exception 'T128 FAIL: unknown subsystem accepted';
    exception when others then perform pg_temp.chk('T128', 'strategy_revision_strategy_revision_id_check', sqlerrm);
    end;
    insert into sgpt.strategy_revision (strategy_revision_id, parent_revision_id, description,
        trading_affecting, owner_note)
    values ('R-20260912-BOTC-01', 'R-20260901-MULTI-01',
            'Tightened the conviction threshold.', true, 'Candidate for the next comparison period.');
end $$;

-- T129: a revision moves through its states in order, and the
-- trading-affecting classification is fixed once it is live — it drives
-- the 20-trade rule, so it cannot be rewritten after trades were taken.
do $$ begin
    begin
        update sgpt.strategy_revision set state = 'approved', finished_at = now()
         where strategy_revision_id = 'R-20260912-BOTC-01';
        raise exception 'T129 FAIL: a draft revision was approved without running';
    exception when others then perform pg_temp.chk('T129', 'illegal state change', sqlerrm);
    end;
    update sgpt.strategy_revision set state = 'running', activated_at = now(), activated_code_version = 'g4testsha'
     where strategy_revision_id = 'R-20260912-BOTC-01';
    begin
        update sgpt.strategy_revision set trading_affecting = false
         where strategy_revision_id = 'R-20260912-BOTC-01';
        raise exception 'T129 FAIL: classification rewritten after the revision went live';
    exception when others then perform pg_temp.chk('T129', 'classification is fixed once the revision is live', sqlerrm);
    end;
    begin
        delete from sgpt.strategy_revision where strategy_revision_id = 'R-20260912-BOTC-01';
        raise exception 'T129 FAIL: revision deleted';
    exception when others then perform pg_temp.chk('T129', 'cannot be deleted', sqlerrm);
    end;
end $$;

-- T130: qualification counts only trades that exited by their own rules
-- (V13-D7). Forced closes stay in the record, labelled, and are excluded.
do $$
declare v record; v_expected int;
begin
    select * into v from sgpt.revision_qualification_v
     where strategy_revision_id = 'R-20260901-MULTI-01';
    select count(*) into v_expected from sgpt.trade
     where status = 'closed' and close_reason in ('target', 'stop', 'month_end');
    if v.qualifying_trades <> v_expected then
        raise exception 'T130 FAIL: qualifying count % does not match the trades that exited by their own rules (%)',
            v.qualifying_trades, v_expected;
    end if;
    if exists (select 1 from sgpt.qualifying_trade_v
                where counts_toward_qualification
                  and close_reason not in ('target', 'stop', 'month_end')) then
        raise exception 'T130 FAIL: a forced close was counted toward qualification';
    end if;
    if v.forced_close_trades = 0 then
        raise exception 'T130 FAIL: forced closes should still appear in the record, labelled';
    end if;
    if v.closed_trades <> v.qualifying_trades + v.forced_close_trades then
        raise exception 'T130 FAIL: closed trades do not reconcile';
    end if;
    if v.minimum_met then
        raise exception 'T130 FAIL: minimum reported as met on % qualifying trades', v.qualifying_trades;
    end if;
end $$;

-- T131: a platform version change restarts the go-live count. A forced
-- IBKR upgrade is not waved through; the count starts again.
do $$
declare v record; v_change timestamptz;
begin
    select max(at_time) into v_change from sgpt.platform_version_change_v;
    if v_change is null then
        raise exception 'T131 FAIL: platform version changes are not being detected from the run stamps';
    end if;
    select * into v from sgpt.go_live_readiness_v where strategy_revision_id = 'R-20260901-MULTI-01';
    if v.counting_from <> v_change then
        raise exception 'T131 FAIL: the count should restart at the platform change (%), got %',
            v_change, v.counting_from;
    end if;
    if v.qualifying_trades_since <> (select count(*) from sgpt.qualifying_trade_v
                                      where counts_toward_qualification and closed_at >= v_change) then
        raise exception 'T131 FAIL: go-live count does not match the trades closed since the platform change';
    end if;
end $$;

-- T132: the operator control log is evidence. Write once, keep forever.
select pg_temp.new_run('runC4', '2026-09-08', 'V1', 'verification_checkpoint');
do $$ begin
    begin
        insert into sgpt.operator_control_log (control_code, prior_value, new_value, owner_note,
            active_strategy_revision_id)
        values ('manual_risk_multiplier', '1.00', '1.00', 'no change at all', 'R-20260901-MULTI-01');
        raise exception 'T132 FAIL: a control change that changed nothing was logged';
    exception when others then perform pg_temp.chk('T132', 'operator_control_log_changed_chk', sqlerrm);
    end;
    begin
        insert into sgpt.operator_control_log (control_code, prior_value, new_value, owner_note,
            active_strategy_revision_id, changed_by)
        values ('track_halt', 'false', 'true', 'automatic but nameless', 'R-20260901-MULTI-01', 'system');
        raise exception 'T132 FAIL: an automatic change was logged without naming its run';
    exception when others then perform pg_temp.chk('T132', 'a system change names its run', sqlerrm);
    end;
    insert into sgpt.operator_control_log (control_code, track_code, prior_value, new_value, owner_note,
        active_strategy_revision_id, changed_by, window_run_id)
    values ('track_halt', 'PRIMARY', 'false', 'true', 'Reconciliation mismatch confirmed.',
            'R-20260901-MULTI-01', 'system', pg_temp.id('runC4'));
    begin
        update sgpt.operator_control_log set owner_note = 'tidied up later'
         where control_code = 'track_halt';
        raise exception 'T132 FAIL: a control log entry was amended';
    exception when others then perform pg_temp.chk('T132', 'write-once', sqlerrm);
    end;
    begin
        delete from sgpt.operator_control_log where control_code = 'track_halt';
        raise exception 'T132 FAIL: a control log entry was deleted';
    exception when others then perform pg_temp.chk('T132', 'write-once', sqlerrm);
    end;
end $$;

-- T133: standing a protection down is a record, not an absence. At MVP the
-- 20-trade rule is advisory; a promotion made short of the count is written
-- down with the owner's reason.
do $$ begin
    insert into sgpt.operator_control_log (control_code, prior_value, new_value, owner_note,
        active_strategy_revision_id)
    values ('qualification_override', '12 qualifying trades', 'promoted anyway',
            'Promoted at 12 rather than 20: the change was a data-source swap with identical outputs.',
            'R-20260901-MULTI-01');
    if not exists (select 1 from sgpt.operator_control_log where control_code = 'qualification_override') then
        raise exception 'T133 FAIL: the override was not recorded';
    end if;
end $$;

-- T134: the Halt log. A track Halt names its track, an automatic Halt names
-- its run, and only the owner releases one.
do $$ begin
    begin
        insert into sgpt.halt_log (halt_scope, action, reason, set_by, window_run_id)
        values ('track', 'set', 'no track named', 'system', pg_temp.id('runC4'));
        raise exception 'T134 FAIL: a track Halt was logged without naming its track';
    exception when others then perform pg_temp.chk('T134', 'halt_log_scope_chk', sqlerrm);
    end;
    insert into sgpt.halt_log (halt_scope, track_code, action, reason, set_by, window_run_id)
    values ('track', 'PRIMARY', 'set', 'Reconciliation mismatch confirmed on MSFT.', 'system', pg_temp.id('runC4'));
    begin
        insert into sgpt.halt_log (halt_scope, track_code, action, reason, set_by, window_run_id)
        values ('track', 'PRIMARY', 'released', 'system decided it was fine', 'system', pg_temp.id('runC4'));
        raise exception 'T134 FAIL: the system released a Halt';
    exception when others then perform pg_temp.chk('T134', 'released by the owner', sqlerrm);
    end;
    insert into sgpt.halt_log (halt_scope, track_code, action, reason, set_by)
    values ('track', 'PRIMARY', 'released', 'Reviewed the mismatch and resolved it in IBKR.', 'owner');
    begin
        delete from sgpt.halt_log where halt_scope = 'track';
        raise exception 'T134 FAIL: a Halt log entry was deleted';
    exception when others then perform pg_temp.chk('T134', 'write-once', sqlerrm);
    end;
end $$;
select pg_temp.end_run(pg_temp.id('runC4'));

-- T135: the classification of a setting is data the system can check, not
-- a convention someone remembers.
do $$ begin
    if (select classification from sgpt.revision_parameter where parameter_code = 'window_time')
       <> 'revision_triggering' then
        raise exception 'T135 FAIL: schedule times must be revision-triggering (V13-D4)';
    end if;
    if (select classification from sgpt.revision_parameter where parameter_code = 'manual_risk_multiplier')
       <> 'operator_control' then
        raise exception 'T135 FAIL: the Manual Risk Multiplier must be an operator control';
    end if;
    begin
        delete from sgpt.revision_parameter where parameter_code = 'window_time';
        raise exception 'T135 FAIL: a parameter was deleted from the classification list';
    exception when others then perform pg_temp.chk('T135', 'retire a parameter, do not delete it', sqlerrm);
    end;
end $$;

-- =====================================================================
-- broker_order_status_history and notification
-- =====================================================================

-- A live order, so the no-change case below is exercised against a real
-- working order rather than only against the finished ones.
select pg_temp.new_run('runE4', '2026-09-08', 'W3', 'trading_window');
select pg_temp.start_step(pg_temp.id('runE4'), 'bot_c');
insert into sgpt.bot_c_decision (window_run_id, instrument_code, decision_type, trade_type, direction,
    expected_entry_cost, max_loss, position_quantity, legs, exit_plan, decision_summary)
values (pg_temp.id('runE4'), 'AAPL', 'proposal', 'bull_call_spread', 'bullish',
        350, 350, 1, '[]'::jsonb, '{}'::jsonb, 'G4 test proposal');
select pg_temp.start_step(pg_temp.id('runE4'), 'bot_d');
insert into sgpt.bot_d_verification (window_run_id, instrument_code, live_entry_cost, cost_variance_pct,
    cost_tolerance_pct, available_cash, cash_covers_max_loss, portfolio_mode_ok, blackout_clear, outcome)
values (pg_temp.id('runE4'), 'AAPL', 360, 2.86, 5.00, 15000, true, true, true, 'submitted');
do $$
declare v_t uuid; v_o uuid;
begin
    insert into sgpt.trade (window_run_id, track_code, broker_account_id, instrument_code, trade_date,
        trade_type, direction, requested_quantity, updated_by_window_run_id)
    select r.window_run_id, r.track_code, r.broker_account_id, 'AAPL', r.trade_date,
           'bull_call_spread', 'bullish', 1, r.window_run_id
      from sgpt.window_run r where r.window_run_id = pg_temp.id('runE4')
    returning trade_id into v_t;
    insert into k4 values ('tAAPL4', v_t);
    insert into sgpt.trade_leg (trade_id, leg_number, sec_type, ibkr_con_id, symbol,
        option_right, strike, expiration, entry_action)
    select v_t, 1, 'OPT', abs(hashtext(t.trade_ref || '1')), 'AAPL', 'C', 100, '2026-10-16', 'BUY'
      from sgpt.trade t where t.trade_id = v_t;
    insert into sgpt.trade_leg (trade_id, leg_number, sec_type, ibkr_con_id, symbol,
        option_right, strike, expiration, entry_action)
    select v_t, 2, 'OPT', abs(hashtext(t.trade_ref || '2')), 'AAPL', 'C', 110, '2026-10-16', 'SELL'
      from sgpt.trade t where t.trade_id = v_t;
    insert into sgpt.broker_order (trade_id, broker_account_id, order_role, action, order_type,
        limit_price, time_in_force, good_till, quantity,
        submitted_by_window_run_id, last_synced_by_window_run_id)
    select t.trade_id, t.broker_account_id, 'entry', 'BUY', 'LMT', 1.75, 'GTD',
           (t.trade_date + s.entry_order_expiry_et) at time zone 'America/New_York',
           1, t.window_run_id, t.window_run_id
      from sgpt.trade t
      join sgpt.window_run r on r.window_run_id = t.window_run_id
      join sgpt.schedule_slot s on s.slot_code = r.slot_code
     where t.trade_id = v_t
    returning broker_order_id into v_o;
    insert into k4 values ('oAAPL4', v_o);
    update sgpt.broker_order set status = 'working', ibkr_order_id = 9001, ibkr_perm_id = 700900001,
           last_synced_by_window_run_id = pg_temp.id('runE4'), last_status_at = now()
     where broker_order_id = v_o;
end $$;

-- T136: the history is written by the database, so it cannot drift from
-- the orders it describes. Checked across EVERY order in the fixture:
-- each chain starts from nothing, every step continues from the one
-- before it, and the last step is the order's current status.
do $$
declare v_bad int;
begin
    if (select count(*) from sgpt.broker_order_status_history) = 0 then
        raise exception 'T136 FAIL: no order history was recorded at all';
    end if;
    select count(*) into v_bad from (
        select h.broker_order_id, h.prior_status,
               lag(h.new_status) over (partition by h.broker_order_id
                                       order by h.broker_order_status_history_id) as previous_new
        from sgpt.broker_order_status_history h) x
     where prior_status is distinct from previous_new;
    if v_bad > 0 then
        raise exception 'T136 FAIL: % history rows do not continue from the step before them', v_bad;
    end if;
    select count(*) into v_bad from sgpt.broker_order o
     where o.status <> (select h.new_status from sgpt.broker_order_status_history h
                         where h.broker_order_id = o.broker_order_id
                         order by h.broker_order_status_history_id desc limit 1);
    if v_bad > 0 then
        raise exception 'T136 FAIL: % orders disagree with the last step of their own history', v_bad;
    end if;
    -- Every step names the run that observed it.
    if exists (select 1 from sgpt.broker_order_status_history where observed_by_window_run_id is null) then
        raise exception 'T136 FAIL: a status change was recorded with no run attached';
    end if;
end $$;

-- T137: a re-read that finds no change is not an event, and the history is
-- never edited or deleted.
do $$
declare v_order uuid; v_before int; v_after int;
begin
    v_order := pg_temp.id('oAAPL4');
    select count(*) into v_before from sgpt.broker_order_status_history where broker_order_id = v_order;
    -- Broker Sync re-reads the order and finds it unchanged.
    update sgpt.broker_order set status_detail = 'resynced, still working',
           last_synced_by_window_run_id = pg_temp.id('runE4'), last_status_at = now()
     where broker_order_id = v_order;
    select count(*) into v_after from sgpt.broker_order_status_history where broker_order_id = v_order;
    if v_after <> v_before then
        raise exception 'T137 FAIL: a sync that changed nothing added % history row(s)', v_after - v_before;
    end if;
    if exists (select 1 from sgpt.broker_order_status_history where prior_status = new_status) then
        raise exception 'T137 FAIL: a status change was recorded from a status to itself';
    end if;
    begin
        update sgpt.broker_order_status_history set new_status = 'cancelled'
         where broker_order_id = v_order;
        raise exception 'T137 FAIL: order history was edited';
    exception when others then perform pg_temp.chk('T137', 'written by the database and is never edited', sqlerrm);
    end;
    begin
        delete from sgpt.broker_order_status_history where broker_order_id = v_order;
        raise exception 'T137 FAIL: order history was deleted';
    exception when others then perform pg_temp.chk('T137', 'written by the database and is never edited', sqlerrm);
    end;
end $$;

select pg_temp.end_run(pg_temp.id('runE4'));

-- T138: an urgent alert must go somewhere the owner will see it. An alert
-- visible only by logging in is not an alert.
do $$ begin
    begin
        insert into sgpt.notification (urgency, category, subject, body, channel)
        values ('urgent', 'unmatched_position', 'Unmatched TSLA position',
                'IBKR reports 200 short shares the system cannot account for.', 'dashboard_only');
        raise exception 'T138 FAIL: urgent alert accepted with no way to reach the owner';
    exception when others then perform pg_temp.chk('T138', 'needs a channel that reaches the owner', sqlerrm);
    end;
    begin
        insert into sgpt.notification (urgency, category, subject, body, channel,
            delivery_status, sent_at)
        values ('normal', 'daily_summary', 'Daily summary', 'Nothing to report.', 'email',
                'sent', now());
        raise exception 'T138 FAIL: a notification was recorded as already sent';
    exception when others then perform pg_temp.chk('T138', 'recorded before it is sent', sqlerrm);
    end;
end $$;

-- T139: the message is immutable, a failed send is a recorded fact, and a
-- sent notification is final.
do $$
declare v uuid;
begin
    insert into sgpt.notification (urgency, category, subject, body, channel)
    values ('urgent', 'halt', 'PRIMARY halted',
            'Reconciliation mismatch confirmed on MSFT. New entries are blocked.', 'email')
    returning notification_id into v;

    -- A send that failed is written down, not swallowed.
    update sgpt.notification set delivery_status = 'failed', attempts = 1,
           delivery_detail = 'SMTP timeout' where notification_id = v;
    begin
        update sgpt.notification set attempts = 0 where notification_id = v;
        raise exception 'T139 FAIL: the attempt count went backwards';
    exception when others then perform pg_temp.chk('T139', 'attempt count cannot go backwards', sqlerrm);
    end;
    begin
        update sgpt.notification set body = 'never mind, everything is fine' where notification_id = v;
        raise exception 'T139 FAIL: the message was rewritten after the fact';
    exception when others then perform pg_temp.chk('T139', 'the message itself is immutable', sqlerrm);
    end;

    update sgpt.notification set delivery_status = 'sent', sent_at = now(), attempts = 2
     where notification_id = v;
    begin
        update sgpt.notification set delivery_status = 'failed', delivery_detail = 'changed my mind'
         where notification_id = v;
        raise exception 'T139 FAIL: a sent notification was changed';
    exception when others then perform pg_temp.chk('T139', 'already sent and cannot be changed', sqlerrm);
    end;
    begin
        delete from sgpt.notification where notification_id = v;
        raise exception 'T139 FAIL: a notification was deleted';
    exception when others then perform pg_temp.chk('T139', 'cannot be deleted', sqlerrm);
    end;
end $$;

select 'G4 TESTS PASSED' as result;
