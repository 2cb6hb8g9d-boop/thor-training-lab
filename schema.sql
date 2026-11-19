-- THOR TRAINING LAB: Supabase/PostgreSQL starter schema
create extension if not exists pgcrypto;
create type public.member_role as enum ('coach','athlete');
create table public.profiles (id uuid primary key references auth.users(id) on delete cascade, full_name text not null, role public.member_role not null default 'athlete', created_at timestamptz not null default now());
create table public.clients (id uuid primary key default gen_random_uuid(), coach_id uuid not null references public.profiles(id), athlete_id uuid references public.profiles(id), full_name text not null, goal text, status text not null default 'active', date_of_birth date, height_cm numeric(5,2), created_at timestamptz not null default now());
create table public.muscle_groups (id uuid primary key default gen_random_uuid(), name text unique not null);
create table public.exercises (id uuid primary key default gen_random_uuid(), name text not null, equipment text, movement_pattern text, notes text, created_by uuid references public.profiles(id));
create table public.exercise_muscles (exercise_id uuid references public.exercises(id) on delete cascade, muscle_id uuid references public.muscle_groups(id), role text not null check(role in ('primary','secondary')), fractional_coefficient numeric(3,2) not null default 1 check(fractional_coefficient between 0 and 1), primary key(exercise_id,muscle_id));
create table public.programs (id uuid primary key default gen_random_uuid(), coach_id uuid not null references public.profiles(id), client_id uuid references public.clients(id), name text not null, goal text, days_per_week int check(days_per_week between 1 and 7), status text default 'draft', created_at timestamptz default now());
create table public.program_days (id uuid primary key default gen_random_uuid(), program_id uuid not null references public.programs(id) on delete cascade, day_number int not null, name text not null);
create table public.program_exercises (id uuid primary key default gen_random_uuid(), program_day_id uuid not null references public.program_days(id) on delete cascade, exercise_id uuid not null references public.exercises(id), sort_order int not null, target_sets int, rep_min int, rep_max int, target_rir numeric(3,1), rest_seconds int, tempo text, notes text);
create table public.workout_sessions (id uuid primary key default gen_random_uuid(), athlete_id uuid not null references public.profiles(id), program_id uuid references public.programs(id), program_day_id uuid references public.program_days(id), name text not null, performed_at timestamptz not null default now(), notes text);
create table public.set_logs (id uuid primary key default gen_random_uuid(), session_id uuid not null references public.workout_sessions(id) on delete cascade, exercise_id uuid not null references public.exercises(id), set_number int not null, load_kg numeric(7,2), reps int, rpe numeric(3,1), rir numeric(3,1), is_warmup boolean not null default false, created_at timestamptz default now());
create table public.body_metrics (id uuid primary key default gen_random_uuid(), athlete_id uuid not null references public.profiles(id), measured_at date not null default current_date, weight_kg numeric(6,2), body_fat_pct numeric(5,2), waist_cm numeric(6,2), notes text);
create table public.nutrition_logs (id uuid primary key default gen_random_uuid(), athlete_id uuid not null references public.profiles(id), logged_on date not null default current_date, calories int, protein_g numeric(6,1), carbs_g numeric(6,1), fat_g numeric(6,1), notes text, unique(athlete_id,logged_on));
-- Enable RLS on user-owned tables. Add production policies after confirming coach/athlete invitation workflow.
alter table public.profiles enable row level security;
alter table public.clients enable row level security;
alter table public.programs enable row level security;
alter table public.workout_sessions enable row level security;
alter table public.set_logs enable row level security;
alter table public.body_metrics enable row level security;
alter table public.nutrition_logs enable row level security;
-- Minimal self-profile policy. Production policies must validate coach-client relationships.
create policy "read own profile" on public.profiles for select using (id = auth.uid());
create policy "update own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());


-- Custom muscle contribution and hybrid progression settings
create table public.exercise_progression_settings (
  exercise_id uuid primary key references public.exercises(id) on delete cascade,
  rep_min int not null default 8 check (rep_min between 1 and 50),
  rep_max int not null default 12 check (rep_max between rep_min and 100),
  target_rir numeric(3,1) not null default 2 check (target_rir between 0 and 5),
  load_increment_kg numeric(5,2) not null default 2.5 check (load_increment_kg > 0),
  progression_method text not null default 'hybrid' check (progression_method = 'hybrid')
);

create table public.muscle_volume_targets (
  id uuid primary key default gen_random_uuid(),
  athlete_id uuid not null references public.profiles(id) on delete cascade,
  muscle_id uuid not null references public.muscle_groups(id) on delete cascade,
  min_effective_sets numeric(5,2) not null default 8,
  max_effective_sets numeric(5,2) not null default 16,
  unique(athlete_id, muscle_id),
  check(min_effective_sets >= 0 and max_effective_sets >= min_effective_sets)
);

alter table public.exercise_muscles enable row level security;
alter table public.exercise_progression_settings enable row level security;
alter table public.muscle_volume_targets enable row level security;

-- Production note: add relationship-aware coach/athlete RLS policies
-- before connecting real client accounts.


-- v1.3: coach / athlete assignments and weekly check-ins
create table if not exists public.program_assignments (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  program_id uuid not null references public.programs(id) on delete cascade,
  start_date date not null default current_date,
  status text not null default 'active' check(status in ('planned','active','completed')),
  created_at timestamptz not null default now()
);

create table if not exists public.coach_checkins (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  checkin_date date not null default current_date,
  weight_kg numeric(6,2),
  sessions_completed int not null default 0 check(sessions_completed >= 0),
  sessions_planned int not null default 1 check(sessions_planned > 0),
  average_sleep_hours numeric(3,1) check(average_sleep_hours between 0 and 24),
  stress_score int not null default 3 check(stress_score between 1 and 5),
  recovery_score int not null default 3 check(recovery_score between 1 and 5),
  nutrition_adherence_score int not null default 3 check(nutrition_adherence_score between 1 and 5),
  coach_notes text,
  created_at timestamptz not null default now(),
  check(sessions_completed <= sessions_planned)
);

alter table public.program_assignments enable row level security;
alter table public.coach_checkins enable row level security;
alter table public.program_days enable row level security;
alter table public.program_exercises enable row level security;

-- Relationship-aware access. The coach can access records for their own client
-- relationships; an athlete can access only the relationship linked to their profile.
create policy "coach and athlete read client relationship" on public.clients
for select using (coach_id = auth.uid() or athlete_id = auth.uid());
create policy "coach manages own clients" on public.clients
for all using (coach_id = auth.uid()) with check (coach_id = auth.uid());

create policy "coach and linked athlete read programs" on public.programs
for select using (
  coach_id = auth.uid()
  or exists (select 1 from public.clients c where c.id = programs.client_id and c.athlete_id = auth.uid())
);
create policy "coach manages own programs" on public.programs
for all using (coach_id = auth.uid()) with check (coach_id = auth.uid());

create policy "read assigned program days" on public.program_days
for select using (exists (
  select 1 from public.programs p
  left join public.clients c on c.id = p.client_id
  where p.id = program_days.program_id and (p.coach_id = auth.uid() or c.athlete_id = auth.uid())
));
create policy "coach manages program days" on public.program_days
for all using (exists (select 1 from public.programs p where p.id = program_days.program_id and p.coach_id = auth.uid()))
with check (exists (select 1 from public.programs p where p.id = program_days.program_id and p.coach_id = auth.uid()));

create policy "read assigned program exercises" on public.program_exercises
for select using (exists (
  select 1 from public.program_days d join public.programs p on p.id = d.program_id
  left join public.clients c on c.id = p.client_id
  where d.id = program_exercises.program_day_id and (p.coach_id = auth.uid() or c.athlete_id = auth.uid())
));
create policy "coach manages program exercises" on public.program_exercises
for all using (exists (
  select 1 from public.program_days d join public.programs p on p.id = d.program_id
  where d.id = program_exercises.program_day_id and p.coach_id = auth.uid()
)) with check (exists (
  select 1 from public.program_days d join public.programs p on p.id = d.program_id
  where d.id = program_exercises.program_day_id and p.coach_id = auth.uid()
));

create policy "coach and athlete read program assignments" on public.program_assignments
for select using (exists (
  select 1 from public.clients c where c.id = program_assignments.client_id
  and (c.coach_id = auth.uid() or c.athlete_id = auth.uid())
));
create policy "coach manages program assignments" on public.program_assignments
for all using (exists (select 1 from public.clients c where c.id = program_assignments.client_id and c.coach_id = auth.uid()))
with check (exists (select 1 from public.clients c where c.id = program_assignments.client_id and c.coach_id = auth.uid()));

create policy "coach and athlete read checkins" on public.coach_checkins
for select using (exists (
  select 1 from public.clients c where c.id = coach_checkins.client_id
  and (c.coach_id = auth.uid() or c.athlete_id = auth.uid())
));
create policy "coach manages checkins" on public.coach_checkins
for all using (exists (select 1 from public.clients c where c.id = coach_checkins.client_id and c.coach_id = auth.uid()))
with check (exists (select 1 from public.clients c where c.id = coach_checkins.client_id and c.coach_id = auth.uid()));

create policy "athlete and coach read workout sessions" on public.workout_sessions
for select using (
  athlete_id = auth.uid()
  or exists (select 1 from public.clients c where c.athlete_id = workout_sessions.athlete_id and c.coach_id = auth.uid())
);
create policy "athlete creates own workout sessions" on public.workout_sessions
for insert with check (athlete_id = auth.uid());
create policy "athlete updates own workout sessions" on public.workout_sessions
for update using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());

create policy "athlete and coach read set logs" on public.set_logs
for select using (exists (
  select 1 from public.workout_sessions w
  where w.id = set_logs.session_id and (
    w.athlete_id = auth.uid()
    or exists (select 1 from public.clients c where c.athlete_id = w.athlete_id and c.coach_id = auth.uid())
  )
));
create policy "athlete manages own set logs" on public.set_logs
for all using (exists (select 1 from public.workout_sessions w where w.id = set_logs.session_id and w.athlete_id = auth.uid()))
with check (exists (select 1 from public.workout_sessions w where w.id = set_logs.session_id and w.athlete_id = auth.uid()));

create policy "athlete and coach read body metrics" on public.body_metrics
for select using (athlete_id = auth.uid() or exists (
  select 1 from public.clients c where c.athlete_id = body_metrics.athlete_id and c.coach_id = auth.uid()
));
create policy "athlete manages own body metrics" on public.body_metrics
for all using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());

create policy "athlete and coach read nutrition logs" on public.nutrition_logs
for select using (athlete_id = auth.uid() or exists (
  select 1 from public.clients c where c.athlete_id = nutrition_logs.athlete_id and c.coach_id = auth.uid()
));
create policy "athlete manages own nutrition logs" on public.nutrition_logs
for all using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());

create policy "authenticated read exercise muscle map" on public.exercise_muscles
for select using (auth.uid() is not null);
create policy "authenticated read progression settings" on public.exercise_progression_settings
for select using (auth.uid() is not null);
create policy "athlete and coach read volume targets" on public.muscle_volume_targets
for select using (athlete_id = auth.uid() or exists (
  select 1 from public.clients c where c.athlete_id = muscle_volume_targets.athlete_id and c.coach_id = auth.uid()
));
create policy "athlete manages own volume targets" on public.muscle_volume_targets
for all using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());

-- Before production: add a verified invitation / account-linking flow that
-- populates clients.athlete_id only after the athlete accepts the invitation.
