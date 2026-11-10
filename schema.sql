
create extension if not exists pgcrypto;

-- USER PROFILES
create table public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text not null default 'Member',
    bio text default '',
    avatar_url text,
    created_at timestamptz default now()
);

-- SKILLS
create table public.skills (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    name text not null,
    category text not null default 'Other',
    skill_type text not null check (skill_type in ('teach', 'learn')),
    created_at timestamptz default now()
);

create index skills_name_idx on public.skills using gin (to_tsvector('english', name));
create index skills_user_idx on public.skills(user_id);

-- EXCHANGE REQUESTS
create table public.exchange_requests (
    id uuid primary key default gen_random_uuid(),
    sender_id uuid not null references public.profiles(id) on delete cascade,
    receiver_id uuid not null references public.profiles(id) on delete cascade,
    message text default '',
    status text not null default 'pending'
        check (status in ('pending', 'accepted', 'rejected', 'completed')),
    created_at timestamptz default now(),
    check (sender_id <> receiver_id)
);

-- CHAT MESSAGES
create table public.messages (
    id uuid primary key default gen_random_uuid(),
    request_id uuid not null references public.exchange_requests(id) on delete cascade,
    sender_id uuid not null references public.profiles(id) on delete cascade,
    content text not null check (length(content) between 1 and 5000),
    created_at timestamptz default now()
);

-- LEARNING SESSIONS
create table public.sessions (
    id uuid primary key default gen_random_uuid(),
    request_id uuid not null references public.exchange_requests(id) on delete cascade,
    scheduled_at timestamptz not null,
    meeting_link text,
    status text default 'scheduled'
        check (status in ('scheduled', 'completed', 'cancelled')),
    created_at timestamptz default now()
);

-- AUTOMATIC PROFILE CREATION
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, display_name)
    values (
        new.id,
        coalesce(new.raw_user_meta_data ->> 'display_name', 'Member')
    );

    return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- ENABLE ROW LEVEL SECURITY
alter table public.profiles enable row level security;
alter table public.skills enable row level security;
alter table public.exchange_requests enable row level security;
alter table public.messages enable row level security;
alter table public.sessions enable row level security;

-- PROFILES
create policy "Profiles are publicly readable"
on public.profiles for select
to authenticated
using (true);

create policy "Users update own profile"
on public.profiles for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

-- SKILLS
create policy "Authenticated users view skills"
on public.skills for select
to authenticated
using (true);

create policy "Users add own skills"
on public.skills for insert
to authenticated
with check (auth.uid() = user_id);

create policy "Users update own skills"
on public.skills for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy "Users delete own skills"
on public.skills for delete
to authenticated
using (auth.uid() = user_id);

-- EXCHANGE REQUESTS
create policy "Participants view requests"
on public.exchange_requests for select
to authenticated
using (auth.uid() = sender_id or auth.uid() = receiver_id);

create policy "Users send requests"
on public.exchange_requests for insert
to authenticated
with check (auth.uid() = sender_id and auth.uid() <> receiver_id);

create policy "Receiver updates request"
on public.exchange_requests for update
to authenticated
using (auth.uid() = receiver_id)
with check (auth.uid() = receiver_id);

-- MESSAGES
create policy "Participants view messages"
on public.messages for select
to authenticated
using (
    exists (
        select 1 from public.exchange_requests r
        where r.id = request_id
        and (auth.uid() = r.sender_id or auth.uid() = r.receiver_id)
        and r.status = 'accepted'
    )
);

create policy "Participants send messages"
on public.messages for insert
to authenticated
with check (
    auth.uid() = sender_id
    and exists (
        select 1 from public.exchange_requests r
        where r.id = request_id
        and (auth.uid() = r.sender_id or auth.uid() = r.receiver_id)
        and r.status = 'accepted'
    )
);

-- SESSIONS
create policy "Participants view sessions"
on public.sessions for select
to authenticated
using (
    exists (
        select 1 from public.exchange_requests r
        where r.id = request_id
        and (auth.uid() = r.sender_id or auth.uid() = r.receiver_id)
    )
);

create policy "Participants create sessions"
on public.sessions for insert
to authenticated
with check (
    exists (
        select 1 from public.exchange_requests r
        where r.id = request_id
        and (auth.uid() = r.sender_id or auth.uid() = r.receiver_id)
        and r.status = 'accepted'
    )
);

-- Prevent duplicate requests between the same two users
create unique index if not exists unique_exchange_pair
on public.exchange_requests(sender_id, receiver_id);

-- SMART SKILL MATCHING
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
as $$
    with my_skills as (
        select
            lower(trim(s.name)) as skill_name,
            s.name,
            s.category,
            s.skill_type
        from public.skills s
        where s.user_id = auth.uid()
    ),

    other_skills as (
        select
            s.user_id,
            s.name,
            lower(trim(s.name)) as skill_name,
            s.category,
            s.skill_type
        from public.skills s
        where s.user_id <> auth.uid()
    ),

    candidate_matches as (
        select
            o.user_id,

            bool_or(
                m.skill_type = 'teach'
                and o.skill_type = 'learn'
                and m.skill_name = o.skill_name
            ) as they_can_learn_from_me,

            bool_or(
                m.skill_type = 'learn'
                and o.skill_type = 'teach'
                and m.skill_name = o.skill_name
            ) as i_can_learn_from_them,

            count(*) filter (
                where m.skill_type = 'teach'
                and o.skill_type = 'learn'
                and m.skill_name = o.skill_name
            ) as outgoing_matches,

            count(*) filter (
                where m.skill_type = 'learn'
                and o.skill_type = 'teach'
                and m.skill_name = o.skill_name
            ) as incoming_matches

        from my_skills m
        join other_skills o
          on m.skill_name = o.skill_name
        group by o.user_id
    ),

    eligible as (
        select *
        from candidate_matches
        where they_can_learn_from_me
           or i_can_learn_from_them
    )

    select
        p.id,
        p.display_name,
        p.bio,

        (
            case
                when e.they_can_learn_from_me
                 and e.i_can_learn_from_them then 70
                else 35
            end
            +
            least(
                20,
                (e.outgoing_matches + e.incoming_matches) * 10
            )
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

    from eligible e
    join public.profiles p on p.id = e.user_id
    order by 4 desc, p.display_name asc
    limit 30;
$$;

revoke all on function public.get_skill_matches() from public;
grant execute on function public.get_skill_matches() to authenticated;

drop policy if exists "Authenticated users view skills"
on public.skills;

create policy "Anyone can view skills"
on public.skills
for select
to anon, authenticated
using (true);

drop policy if exists "Profiles are publicly readable"
on public.profiles;

create policy "Profiles are publicly readable"
on public.profiles
for select
to anon, authenticated
using (true);

-- Limit request updates to the status column
revoke update on public.exchange_requests from authenticated;
grant update(status) on public.exchange_requests to authenticated;
