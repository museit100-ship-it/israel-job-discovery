-- Permit GitHub's delayed daily event after 18:00 on the same Israel day.
-- The (israel_day, trigger) key still permits only one attempt per trigger/day.
do $fix$
declare definition text;
begin
 definition := pg_get_functiondef('public.claim_discovery_run(text)'::regprocedure);
 definition := replace(definition, ' or local_time::time >= time ''18:30''', '');
 execute definition;
end;
$fix$;
