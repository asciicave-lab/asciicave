-- ============================================================
-- AsciiCave — esquema completo de Supabase
-- ============================================================
-- Cómo usar este archivo:
-- 1. Entra en https://supabase.com/dashboard/project/bqsntjnnpewwhgwulfzw
-- 2. Abre "SQL Editor" → "New query"
-- 3. Pega TODO este archivo y pulsa "Run". Es seguro volver a ejecutarlo
--    (usa "if not exists" / "or replace" / "on conflict do nothing" en
--    casi todo), aunque lo normal es ejecutarlo solo una vez.
-- 4. Para dar acceso de administrador a alguien: Table editor → profiles
--    → edita su fila → role = 'admin'. No hay contraseña de admin en el
--    código: el rol vive únicamente aquí, en la base de datos.
-- ============================================================

-- ---------- PERFILES ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  account_type text not null default 'lector' check (account_type in ('lector','autor','ambos')),
  role text not null default 'user' check (role in ('user','admin')),
  avatar_url text,
  patreon_url text,
  points int not null default 0,
  show_adult boolean not null default false,
  onboarded boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "profiles select" on public.profiles;
create policy "profiles select" on public.profiles for select using (true);
drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles insert own" on public.profiles for insert with check (auth.uid() = id);

-- Solo estas columnas son editables directamente por el propio usuario.
-- points / role / account_type / onboarded quedan protegidas: solo las
-- tocan los triggers y funciones "security definer" de abajo.
revoke update on public.profiles from authenticated;
grant update (username, avatar_url, patreon_url, show_adult, account_type, onboarded) on public.profiles to authenticated;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- Crea automáticamente la fila de perfil al registrarse (email o Google).
-- Si el registro por email mandó "username" en los metadatos, se marca
-- onboarded=true (ya eligió nombre y tipo de cuenta en el formulario);
-- si no (login social), onboarded queda en false y la web le pedirá
-- completar el perfil la primera vez.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, account_type, onboarded)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1) || '_' || substr(new.id::text,1,4)),
    coalesce(new.raw_user_meta_data->>'account_type','lector'),
    (new.raw_user_meta_data->>'username') is not null
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------- NOVELAS ----------
create table if not exists public.novels (
  id bigint generated always as identity primary key,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  synopsis text not null,
  genres text[] not null default '{}',
  subgenres text[] not null default '{}',
  is_adult boolean not null default false,
  cover_url text,
  cover_gradient text not null,
  patreon_url text,
  status text not null default 'pendiente' check (status in ('pendiente','aprobada','rechazada')),
  reject_reason text,
  followers_count int not null default 0,
  favs_count int not null default 0,
  views_count int not null default 0,
  votes_count int not null default 0,
  chapters_count int not null default 0,
  rating_historia numeric(4,2) not null default 0,
  rating_estilo numeric(4,2) not null default 0,
  rating_gramatica numeric(4,2) not null default 0,
  rating_personajes numeric(4,2) not null default 0,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
alter table public.novels enable row level security;
create index if not exists idx_novels_status on public.novels(status);
create index if not exists idx_novels_owner on public.novels(owner_id);

drop policy if exists "novels select" on public.novels;
create policy "novels select" on public.novels for select using (
  status = 'aprobada' or owner_id = auth.uid() or public.is_admin()
);
drop policy if exists "novels insert own" on public.novels;
create policy "novels insert own" on public.novels for insert with check (owner_id = auth.uid());
drop policy if exists "novels update own" on public.novels;
create policy "novels update own" on public.novels for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- El autor solo puede tocar estos campos directamente. status, contadores,
-- medias y reviewed_at están bloqueados: solo los cambian los triggers y
-- las funciones fn_review_novel / fn_resubmit_novel de más abajo.
revoke update on public.novels from authenticated;
grant update (title, synopsis, genres, subgenres, is_adult, cover_url, cover_gradient, patreon_url) on public.novels to authenticated;

-- ---------- CAPÍTULOS ----------
create table if not exists public.chapters (
  id bigint generated always as identity primary key,
  novel_id bigint not null references public.novels(id) on delete cascade,
  idx int not null,
  title text not null,
  body text not null,
  note_start text,
  note_end text,
  views int not null default 0,
  created_at timestamptz not null default now(),
  unique (novel_id, idx)
);
alter table public.chapters enable row level security;
create index if not exists idx_chapters_novel on public.chapters(novel_id, idx);
create index if not exists idx_chapters_created on public.chapters(created_at desc);

drop policy if exists "chapters select" on public.chapters;
create policy "chapters select" on public.chapters for select using (
  exists(select 1 from public.novels n where n.id = novel_id
    and (n.status = 'aprobada' or n.owner_id = auth.uid() or public.is_admin()))
);
drop policy if exists "chapters insert by owner" on public.chapters;
create policy "chapters insert by owner" on public.chapters for insert with check (
  exists(select 1 from public.novels n where n.id = novel_id and n.owner_id = auth.uid())
);
-- No hay policy de update/delete: los capítulos no se editan desde el
-- cliente en esta versión, así que quedan protegidos por defecto.
revoke update on public.chapters from authenticated;

-- ---------- COMENTARIOS ----------
create table if not exists public.comments (
  id bigint generated always as identity primary key,
  chapter_id bigint not null references public.chapters(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  text text not null,
  created_at timestamptz not null default now()
);
alter table public.comments enable row level security;
create index if not exists idx_comments_chapter on public.comments(chapter_id, created_at);
create index if not exists idx_comments_created on public.comments(created_at desc);

drop policy if exists "comments select" on public.comments;
create policy "comments select" on public.comments for select using (true);
drop policy if exists "comments insert own" on public.comments;
create policy "comments insert own" on public.comments for insert with check (auth.uid() = user_id);

-- ---------- SEGUIDORES / FAVORITOS / VALORACIONES ----------
create table if not exists public.follows (
  user_id uuid not null references public.profiles(id) on delete cascade,
  novel_id bigint not null references public.novels(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, novel_id)
);
alter table public.follows enable row level security;
create index if not exists idx_follows_novel_created on public.follows(novel_id, created_at desc);
drop policy if exists "follows select" on public.follows;
create policy "follows select" on public.follows for select using (true);
drop policy if exists "follows insert own" on public.follows;
create policy "follows insert own" on public.follows for insert with check (auth.uid() = user_id);
drop policy if exists "follows delete own" on public.follows;
create policy "follows delete own" on public.follows for delete using (auth.uid() = user_id);

create table if not exists public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  novel_id bigint not null references public.novels(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, novel_id)
);
alter table public.favorites enable row level security;
drop policy if exists "favorites select" on public.favorites;
create policy "favorites select" on public.favorites for select using (true);
drop policy if exists "favorites insert own" on public.favorites;
create policy "favorites insert own" on public.favorites for insert with check (auth.uid() = user_id);
drop policy if exists "favorites delete own" on public.favorites;
create policy "favorites delete own" on public.favorites for delete using (auth.uid() = user_id);

create table if not exists public.ratings (
  user_id uuid not null references public.profiles(id) on delete cascade,
  novel_id bigint not null references public.novels(id) on delete cascade,
  historia smallint not null check (historia between 1 and 5),
  estilo smallint not null check (estilo between 1 and 5),
  gramatica smallint not null check (gramatica between 1 and 5),
  personajes smallint not null check (personajes between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (user_id, novel_id)
);
alter table public.ratings enable row level security;
drop policy if exists "ratings select" on public.ratings;
create policy "ratings select" on public.ratings for select using (true);
drop policy if exists "ratings insert own" on public.ratings;
create policy "ratings insert own" on public.ratings for insert with check (auth.uid() = user_id);
-- Sin policy de update/delete: una valoración enviada es definitiva.

create table if not exists public.reading_progress (
  user_id uuid not null references public.profiles(id) on delete cascade,
  novel_id bigint not null references public.novels(id) on delete cascade,
  read_chapters int[] not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (user_id, novel_id)
);
alter table public.reading_progress enable row level security;
drop policy if exists "reading_progress select own" on public.reading_progress;
create policy "reading_progress select own" on public.reading_progress for select using (auth.uid() = user_id);
drop policy if exists "reading_progress insert own" on public.reading_progress;
create policy "reading_progress insert own" on public.reading_progress for insert with check (auth.uid() = user_id);
drop policy if exists "reading_progress update own" on public.reading_progress;
create policy "reading_progress update own" on public.reading_progress for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- Triggers: mantienen contadores y puntos automáticamente.
-- Corren como "security definer" (dueño postgres), así que pueden
-- escribir en columnas que el cliente tiene bloqueadas por GRANT,
-- pero el cliente nunca puede llamarlos directamente ni falsificarlos.
-- ============================================================

create or replace function public.trg_fn_follows()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.novels set followers_count = followers_count + 1 where id = new.novel_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.novels set followers_count = greatest(followers_count - 1, 0) where id = old.novel_id;
    return old;
  end if;
  return null;
end;
$$;
drop trigger if exists t_follows_count on public.follows;
create trigger t_follows_count after insert or delete on public.follows
  for each row execute procedure public.trg_fn_follows();

create or replace function public.trg_fn_favorites()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.novels set favs_count = favs_count + 1 where id = new.novel_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.novels set favs_count = greatest(favs_count - 1, 0) where id = old.novel_id;
    return old;
  end if;
  return null;
end;
$$;
drop trigger if exists t_favorites_count on public.favorites;
create trigger t_favorites_count after insert or delete on public.favorites
  for each row execute procedure public.trg_fn_favorites();

-- +10 puntos al lector que valora, +2 al autor de la novela valorada.
create or replace function public.trg_fn_ratings()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  update public.novels n set
    rating_historia   = round(((n.rating_historia   * n.votes_count) + new.historia)   / (n.votes_count + 1), 2),
    rating_estilo     = round(((n.rating_estilo     * n.votes_count) + new.estilo)     / (n.votes_count + 1), 2),
    rating_gramatica  = round(((n.rating_gramatica  * n.votes_count) + new.gramatica)  / (n.votes_count + 1), 2),
    rating_personajes = round(((n.rating_personajes * n.votes_count) + new.personajes) / (n.votes_count + 1), 2),
    votes_count = n.votes_count + 1
  where n.id = new.novel_id
  returning n.owner_id into v_owner;

  update public.profiles set points = points + 10 where id = new.user_id;
  if v_owner is not null then
    update public.profiles set points = points + 2 where id = v_owner;
  end if;
  return new;
end;
$$;
drop trigger if exists t_ratings_apply on public.ratings;
create trigger t_ratings_apply after insert on public.ratings
  for each row execute procedure public.trg_fn_ratings();

-- +15 puntos al autor por cada capítulo publicado; mantiene chapters_count.
create or replace function public.trg_fn_chapter_maintain()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  if tg_op = 'INSERT' then
    update public.novels set chapters_count = chapters_count + 1 where id = new.novel_id
      returning owner_id into v_owner;
    if v_owner is not null then
      update public.profiles set points = points + 15 where id = v_owner;
    end if;
    return new;
  elsif tg_op = 'DELETE' then
    update public.novels set chapters_count = greatest(chapters_count - 1, 0) where id = old.novel_id;
    return old;
  end if;
  return null;
end;
$$;
drop trigger if exists t_chapter_maintain on public.chapters;
create trigger t_chapter_maintain after insert or delete on public.chapters
  for each row execute procedure public.trg_fn_chapter_maintain();

-- +3 puntos al comentar, pero solo la primera vez que alguien comenta
-- en un capítulo concreto (evita farmear puntos comentando en bucle).
create or replace function public.trg_fn_comment_points()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_prior int;
begin
  select count(*) into v_prior from public.comments
    where chapter_id = new.chapter_id and user_id = new.user_id and id <> new.id;
  if v_prior = 0 then
    update public.profiles set points = points + 3 where id = new.user_id;
  end if;
  return new;
end;
$$;
drop trigger if exists t_comment_points on public.comments;
create trigger t_comment_points after insert on public.comments
  for each row execute procedure public.trg_fn_comment_points();

-- ============================================================
-- Funciones RPC (acciones que un usuario normal no puede hacer
-- con un simple insert/update por las policies de arriba).
-- ============================================================

create or replace function public.fn_review_novel(p_novel_id bigint, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  if p_decision = 'aprobada' then
    update public.novels set status = 'aprobada', reviewed_at = now(), reject_reason = null where id = p_novel_id;
  elsif p_decision = 'rechazada' then
    update public.novels set status = 'rechazada', reviewed_at = now(), reject_reason = p_reason where id = p_novel_id;
  else
    raise exception 'invalid decision %', p_decision;
  end if;
end;
$$;
grant execute on function public.fn_review_novel(bigint, text, text) to authenticated;

create or replace function public.fn_resubmit_novel(p_novel_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.novels set status = 'pendiente', reject_reason = null
  where id = p_novel_id and owner_id = auth.uid() and status = 'rechazada';
end;
$$;
grant execute on function public.fn_resubmit_novel(bigint) to authenticated;

-- Registra una lectura: cuenta la vista del capítulo y de la novela.
-- Se puede llamar sin sesión (lectura anónima cuenta igual que en el
-- prototipo original), por eso también se concede a "anon".
create or replace function public.fn_register_view(p_chapter_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_novel_id bigint;
begin
  update public.chapters set views = views + 1 where id = p_chapter_id returning novel_id into v_novel_id;
  if v_novel_id is not null then
    update public.novels set views_count = views_count + 1 where id = v_novel_id;
  end if;
end;
$$;
grant execute on function public.fn_register_view(bigint) to authenticated, anon;

-- ---------- Almacenamiento (portadas y avatares) ----------
insert into storage.buckets (id, name, public)
  values ('covers','covers', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public)
  values ('avatars','avatars', true) on conflict (id) do nothing;

drop policy if exists "covers public read" on storage.objects;
create policy "covers public read" on storage.objects for select using (bucket_id = 'covers');
drop policy if exists "covers owner write" on storage.objects;
create policy "covers owner write" on storage.objects for insert with check (
  bucket_id = 'covers' and auth.uid()::text = (storage.foldername(name))[1]
);
drop policy if exists "covers owner update" on storage.objects;
create policy "covers owner update" on storage.objects for update using (
  bucket_id = 'covers' and auth.uid()::text = (storage.foldername(name))[1]
);

drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read" on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists "avatars owner write" on storage.objects;
create policy "avatars owner write" on storage.objects for insert with check (
  bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]
);
drop policy if exists "avatars owner update" on storage.objects;
create policy "avatars owner update" on storage.objects for update using (
  bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]
);

-- ---------- Tiempo real (ranking en vivo) ----------
do $$
begin
  alter publication supabase_realtime add table public.novels;
exception when duplicate_object then null;
end $$;
