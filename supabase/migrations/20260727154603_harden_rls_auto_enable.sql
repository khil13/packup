-- close the API door on the event-trigger function while leaving the trigger itself working
revoke execute on function public.rls_auto_enable() from anon, authenticated, public;
