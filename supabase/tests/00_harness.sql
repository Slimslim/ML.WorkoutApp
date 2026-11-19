-- Test helpers (test database only). ok() raises when a check fails; fails() expects an error.
create schema test_harness;
grant usage on schema test_harness to authenticated, anon;

create function test_harness.ok(cond boolean, msg text) returns void
language plpgsql as $$
begin
  if cond is distinct from true then
    raise exception 'FAILED: %', msg;
  end if;
  raise notice 'ok - %', msg;
end;
$$;

-- Runs `stmt`; passes only when it raises an error whose message contains `expect` (any error
-- when expect is null). Runs as the current role, so RLS and grants apply.
create function test_harness.fails(stmt text, msg text, expect text default null) returns void
language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if expect is not null and position(expect in sqlerrm) = 0 then
      raise exception 'FAILED: % (wrong error: %)', msg, sqlerrm;
    end if;
    raise notice 'ok - % (refused: %)', msg, left(sqlerrm, 120);
    return;
  end;
  raise exception 'FAILED: % (no error)', msg;
end;
$$;
grant execute on all functions in schema test_harness to authenticated, anon;

-- Act as a signed-in user (both claim settings: older and newer auth.uid()).
create function test_harness.login(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, false);
end;
$$;
grant execute on all functions in schema test_harness to authenticated, anon;
