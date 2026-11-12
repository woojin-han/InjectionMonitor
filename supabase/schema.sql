-- =====================================================================
-- 세일체크 (SaleCheck) DB 스키마 · Supabase(PostgreSQL)
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행
-- =====================================================================

-- ---------- 1. 회원 프로필 (auth.users 는 Supabase 가 관리) ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 2 and 20),
  created_at  timestamptz not null default now()
);

-- ---------- 2. 모델 (플랫폼이 달라도 같은 상품을 묶는 단위) ----------
create table if not exists public.models (
  id          bigint generated always as identity primary key,
  brand       text not null,
  model_name  text not null,
  style_code  text unique,                 -- 품번 예: DD1391-100
  category    text not null,
  created_at  timestamptz not null default now()
);

-- ---------- 3. 상품 (플랫폼별 판매 상품) ----------
create table if not exists public.products (
  id             bigint generated always as identity primary key,
  platform       text not null,             -- musinsa | 29cm | shopify:<brand>
  external_id    text not null,             -- 쇼핑몰 상품번호
  model_id       bigint references public.models(id) on delete set null,
  name           text not null,
  brand          text not null,
  category       text not null check (category in ('shoes','top','bottom','outer','etc')),
  list_price     integer not null check (list_price > 0),   -- 정가
  current_price  integer not null check (current_price > 0),-- 현재가
  image_url      text,
  product_url    text not null,
  is_soldout     boolean not null default false,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  unique (platform, external_id)
);
create index if not exists products_category_idx on public.products (category);
create index if not exists products_brand_idx    on public.products (brand);
create index if not exists products_model_idx    on public.products (model_id);

-- ---------- 4. 가격 기록 (상품 × 날짜 = 1행, 그날의 최저 판매가) ----------
create table if not exists public.price_history (
  product_id      bigint not null references public.products(id) on delete cascade,
  collected_date  date   not null,
  sale_price      integer not null,
  list_price      integer not null,
  is_soldout      boolean not null default false,
  collected_at    timestamptz not null default now(),
  primary key (product_id, collected_date)
);

-- ---------- 5. 상품 통계 (수집 후 refresh_product_stats() 로 갱신) ----------
create table if not exists public.product_stats (
  product_id            bigint primary key references public.products(id) on delete cascade,
  all_time_low          integer not null,
  all_time_low_date     date    not null,
  is_new_low            boolean not null default false,  -- 이번 갱신에서 최저가가 새로 내려갔는가
  base_price            integer not null,                -- 최근 30일 중앙값
  display_discount      numeric(5,4) not null,           -- 표시 할인율 0~1
  real_discount         numeric(5,4) not null,           -- 실질 할인율
  list_price_day_ratio  numeric(5,4) not null,           -- 정가 판매일 비율
  days_collected        integer not null,
  first_collected_date  date    not null,
  trust_grade           text not null check (trust_grade in ('real','normal','inflated','insufficient')),
  ai_summary            text,
  ai_summary_at         timestamptz,
  updated_at            timestamptz not null default now()
);
create index if not exists stats_grade_idx on public.product_stats (trust_grade);

-- ---------- 6. 찜 ----------
create table if not exists public.wishlists (
  user_id        uuid   not null references auth.users(id) on delete cascade,
  product_id     bigint not null references public.products(id) on delete cascade,
  price_at_wish  integer not null,
  created_at     timestamptz not null default now(),
  primary key (user_id, product_id)
);

-- ---------- 7. 관심 상품 (목표가 알림) ----------
create table if not exists public.watchlists (
  id             bigint generated always as identity primary key,
  user_id        uuid   not null references auth.users(id) on delete cascade,
  product_id     bigint not null references public.products(id) on delete cascade,
  target_price   integer not null check (target_price > 0),
  notify_target  boolean not null default true,   -- 목표가 이하
  notify_low     boolean not null default true,   -- 역대 최저가 갱신
  created_at     timestamptz not null default now(),
  unique (user_id, product_id)
);

-- ---------- 8. 알림 ----------
create table if not exists public.notifications (
  id          bigint generated always as identity primary key,
  user_id     uuid   not null references auth.users(id) on delete cascade,
  product_id  bigint not null references public.products(id) on delete cascade,
  type        text   not null check (type in ('target_price','all_time_low')),
  message     text   not null,
  price       integer not null,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists noti_user_idx on public.notifications (user_id, is_read, created_at desc);

-- ---------- 9. 수집 실행 기록 ----------
create table if not exists public.crawl_runs (
  id             bigint generated always as identity primary key,
  platform       text not null,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  status         text not null default 'running' check (status in ('running','success','failed')),
  product_count  integer not null default 0,
  error          text
);

-- =====================================================================
-- 목록 화면용 뷰 (상품 + 통계)
-- =====================================================================
create or replace view public.product_list
with (security_invoker = true) as
select p.id, p.platform, p.name, p.brand, p.category, p.list_price, p.current_price,
       p.image_url, p.product_url, p.is_soldout, p.model_id,
       s.all_time_low, s.all_time_low_date, s.base_price,
       s.display_discount, s.real_discount, s.list_price_day_ratio,
       s.days_collected, s.first_collected_date, s.trust_grade, s.ai_summary,
       (p.current_price <= s.all_time_low) as is_all_time_low
from public.products p
join public.product_stats s on s.product_id = p.id;

-- =====================================================================
-- 통계 계산 함수 (계산식: docs/04_시스템설계.md 4절)
-- =====================================================================
create or replace function public.refresh_product_stats()
returns void language sql security definer set search_path = public as $$
  with agg as (
    select h.product_id,
           min(h.sale_price)                                             as atl,
           count(*)                                                      as days,
           min(h.collected_date)                                         as first_date,
           (count(*) filter (where h.sale_price >= h.list_price * 0.98))::numeric
             / count(*)                                                  as lp_ratio,
           percentile_cont(0.5) within group (order by h.sale_price)
             filter (where h.collected_date >= current_date - 30)        as base
    from price_history h
    group by h.product_id
  ),
  atl_date as (
    select distinct on (h.product_id) h.product_id, h.collected_date
    from price_history h join agg a on a.product_id = h.product_id and h.sale_price = a.atl
    order by h.product_id, h.collected_date desc
  ),
  calc as (
    select p.id as product_id, a.atl, d.collected_date as atl_date, a.days, a.first_date,
           a.lp_ratio,
           coalesce(a.base, p.current_price)::int                                as base,
           greatest(0, (p.list_price - p.current_price)::numeric / p.list_price)   as disp,
           greatest(-1, least(1, (coalesce(a.base, p.current_price) - p.current_price)::numeric
                                 / coalesce(a.base, p.current_price)))            as real,
           p.current_price
    from products p
    join agg a      on a.product_id = p.id
    join atl_date d on d.product_id = p.id
  )
  insert into product_stats as ps (product_id, all_time_low, all_time_low_date, is_new_low, base_price,
         display_discount, real_discount, list_price_day_ratio, days_collected,
         first_collected_date, trust_grade, updated_at)
  select c.product_id, c.atl, c.atl_date, false, c.base, c.disp, c.real, c.lp_ratio, c.days,
         c.first_date,
         case
           when c.days < 7 then 'insufficient'
           when c.disp >= 0.30 and c.lp_ratio < 0.10 and c.real < 0.05 then 'inflated'
           when c.real >= 0.10 or (c.current_price <= c.atl * 1.02 and c.current_price < c.base) then 'real'
           else 'normal'
         end,
         now()
  from calc c
  on conflict (product_id) do update set
    is_new_low           = excluded.all_time_low < ps.all_time_low,
    all_time_low         = excluded.all_time_low,
    all_time_low_date    = excluded.all_time_low_date,
    base_price           = excluded.base_price,
    display_discount     = excluded.display_discount,
    real_discount        = excluded.real_discount,
    list_price_day_ratio = excluded.list_price_day_ratio,
    days_collected       = excluded.days_collected,
    first_collected_date = excluded.first_collected_date,
    trust_grade          = excluded.trust_grade,
    updated_at           = now();
$$;

-- =====================================================================
-- 알림 생성 함수 (수집 + 통계 갱신 직후 호출, 같은 알림은 24시간에 1번)
-- =====================================================================
create or replace function public.generate_notifications()
returns integer language plpgsql security definer set search_path = public as $$
declare n1 integer; n2 integer;
begin
  insert into notifications (user_id, product_id, type, message, price)
  select w.user_id, p.id, 'target_price',
         format('%s 가격이 %s원으로 내려가 목표가 %s원 이하가 되었어요', p.name,
                to_char(p.current_price, 'FM999,999,999'), to_char(w.target_price, 'FM999,999,999')),
         p.current_price
  from watchlists w join products p on p.id = w.product_id
  where w.notify_target and not p.is_soldout and p.current_price <= w.target_price
    and not exists (select 1 from notifications n
                    where n.user_id = w.user_id and n.product_id = p.id
                      and n.type = 'target_price' and n.created_at > now() - interval '24 hours');
  get diagnostics n1 = row_count;

  insert into notifications (user_id, product_id, type, message, price)
  select w.user_id, p.id, 'all_time_low',
         format('%s 가격이 역대 최저가 %s원을 기록했어요', p.name, to_char(s.all_time_low, 'FM999,999,999')),
         s.all_time_low
  from watchlists w
  join products p      on p.id = w.product_id
  join product_stats s on s.product_id = p.id
  where w.notify_low and s.is_new_low
    and not exists (select 1 from notifications n
                    where n.user_id = w.user_id and n.product_id = p.id
                      and n.type = 'all_time_low' and n.created_at > now() - interval '24 hours');
  get diagnostics n2 = row_count;
  return n1 + n2;
end $$;

-- 회원가입 시 프로필 자동 생성 (닉네임은 가입 폼의 metadata 에서)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, nickname)
  values (new.id, coalesce(new.raw_user_meta_data->>'nickname', split_part(new.email, '@', 1)));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- 행 수준 보안 (RLS)
-- =====================================================================
alter table public.profiles      enable row level security;
alter table public.models        enable row level security;
alter table public.products      enable row level security;
alter table public.price_history enable row level security;
alter table public.product_stats enable row level security;
alter table public.wishlists     enable row level security;
alter table public.watchlists    enable row level security;
alter table public.notifications enable row level security;
alter table public.crawl_runs    enable row level security;

-- 상품 데이터: 누구나 읽기 (쓰기는 service_role 키를 쓰는 수집기만, RLS 우회)
create policy "public read" on public.models        for select using (true);
create policy "public read" on public.products      for select using (true);
create policy "public read" on public.price_history for select using (true);
create policy "public read" on public.product_stats for select using (true);

-- 내 데이터만
create policy "own profile"  on public.profiles for select using (id = auth.uid());
create policy "own profile u" on public.profiles for update using (id = auth.uid());

create policy "own wish"   on public.wishlists  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own watch"  on public.watchlists for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own noti r" on public.notifications for select using (user_id = auth.uid());
create policy "own noti u" on public.notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 실시간 알림 구독
alter publication supabase_realtime add table public.notifications;
