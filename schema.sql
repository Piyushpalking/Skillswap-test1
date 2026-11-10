
-- 1. Ensure exchange_requests table exists
create table if not exists public.exchange_requests (
    id uuid primary key default gen_random_uuid(),
    sender_id uuid not null references public.profiles(id) on delete cascade,
    receiver_id uuid not null references public.profiles(id) on delete cascade,
    message text default '',
    status text not null default 'pending'
        check (status in ('pending', 'accepted', 'rejected', 'completed')),
    created_at timestamptz default now(),
    check (sender_id <> receiver_id)
);

create index if not exists exchange_requests_sender_idx
on public.exchange_requests(sender_id);

create index if not exists exchange_requests_receiver_idx
on public.exchange_requests(receiver_id);

-- 2. Enable RLS
alter table public.exchange_requests enable row level security;

-- 3. Set permissions
grant select, insert on public.exchange_requests to authenticated;
grant update(status) on public.exchange_requests to authenticated;

-- 4. Recreate policies safely
drop policy if exists "Participants view requests"
on public.exchange_requests;

create policy "Participants view requests"
on public.exchange_requests
for select to authenticated
using (
    auth.uid() = sender_id OR auth.uid() = receiver_id
);

drop policy if exists "Users send requests"
on public.exchange_requests;

create policy "Users send requests"
on public.exchange_requests
for insert to authenticated
with check (
    auth.uid() = sender_id
    AND auth.uid() <> receiver_id
);

drop policy if exists "Receiver updates request"
on public.exchange_requests;

create policy "Receiver updates request"
on public.exchange_requests
for update to authenticated
using (auth.uid() = receiver_id)
with check (auth.uid() = receiver_id);

-- 5. Create matching function
create or replace function public.get_skill_matches()
returns table (
    user_id uuid,
    display_name text,
    bio text,
    score integer,
    offers text[],
    wants text[]
)
language sql
stable
security invoker
set search_path = ''
as $function$
    with my_skills as (
        select
            lower(trim(s.name)) as skill_name,
            s.skill_type
        from public.skills s
        where s.user_id = auth.uid()
    ),

    other_skills as (
        select
            s.user_id,
            lower(trim(s.name)) as skill_name,
            s.skill_type
        from public.skills s
        where s.user_id <> auth.uid()
    ),

    matched as (
        select
            o.user_id,

            count(*) filter (
                where m.skill_type = 'teach'
                and o.skill_type = 'learn'
            ) as outgoing,

            count(*) filter (
                where m.skill_type = 'learn'
                and o.skill_type = 'teach'
            ) as incoming

        from my_skills m
        join other_skills o
          on m.skill_name = o.skill_name

        group by o.user_id
    )

    select
        p.id,
        p.display_name,
        p.bio,

        (
            case
                when m.outgoing > 0 and m.incoming > 0 then 70
                else 35
            end
            + least(20, (m.outgoing + m.incoming) * 10)
        )::integer,

        coalesce((
            select array_agg(distinct s.name)
            from public.skills s
            where s.user_id = p.id
              and s.skill_type = 'teach'
        ), array[]::text[]),

        coalesce((
            select array_agg(distinct s.name)
            from public.skills s
            where s.user_id = p.id
              and s.skill_type = 'learn'
        ), array[]::text[])

    from matched m
    join public.profiles p on p.id = m.user_id
    where m.outgoing > 0 or m.incoming > 0
    order by 4 desc
    limit 30;
$function$;

-- 6. Function permissions
revoke all on function public.get_skill_matches() from public;
grant execute on function public.get_skill_matches() to authenticated;

-- 7. Refresh Supabase API schema cache
notify pgrst, 'reload schema';
