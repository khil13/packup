-- the authenticated role can attempt CRUD; RLS still restricts it to the owner's own rows
grant select, insert, update, delete on public.leads to authenticated, service_role;
grant select, insert, update, delete on public.company_settings to authenticated, service_role;

-- keep future tables working too, so this class of bug doesn't recur
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated, service_role;
