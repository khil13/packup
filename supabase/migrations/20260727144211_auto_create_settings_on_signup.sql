-- when a new auth user is created, give them a default settings row
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.company_settings (owner)
  values (new.id)
  on conflict (owner) do nothing;
  return new;
end;
$$;

-- only the auth system triggers this; not callable via the API
revoke execute on function public.handle_new_user() from anon, authenticated, public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
