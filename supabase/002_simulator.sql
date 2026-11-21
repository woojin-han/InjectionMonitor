-- =====================================================================
-- 002_simulator.sql : 데모용 가격 시뮬레이터
-- schema.sql 을 먼저 실행한 DB 에서, Supabase SQL Editor 에 통째로 붙여넣고 Run.
-- 여러 번 실행해도 안전하다. (이미 schema.sql 을 실행했다면 그대로 덧붙이면 된다)
--
--   select sim_seed();        -- 가상 상품과 90일치 가격 기록을 만든다 (처음 한 번)
--   select sim_next_day();    -- 하루 지나기: 새 가격 → 통계 → 관심 상품 알림 (시연용)
--   select sim_seed(90,true); -- 데모 데이터를 지우고 처음부터 다시 만든다
--
-- 모든 상품, 브랜드, 쇼핑몰 이름은 가상이다. 실제 쇼핑몰의 가격이 아니다.
-- =====================================================================

-- ---------- 0. schema.sql 최신 변경 반영 (이미 반영돼 있으면 아무 일도 안 한다) ----------
alter table public.models   add column if not exists is_demo boolean not null default false;
alter table public.products add column if not exists is_demo boolean not null default false;

create or replace view public.product_list
with (security_invoker = true) as
select p.id, p.platform, p.name, p.brand, p.category, p.list_price, p.current_price,
       p.image_url, p.product_url, p.is_soldout, p.model_id,
       s.all_time_low, s.all_time_low_date, s.base_price,
       s.display_discount, s.real_discount, s.list_price_day_ratio,
       s.days_collected, s.first_collected_date, s.trust_grade, s.ai_summary,
       (p.current_price <= s.all_time_low) as is_all_time_low,
       p.is_demo
from public.products p
join public.product_stats s on s.product_id = p.id;

-- 통계 함수: schema.sql 의 최신 버전과 같다 (기준가 30일 창을 상품의 마지막 기록일 기준으로 계산,
-- 평소보다 3% 이상 싸야 '진짜 할인')
create or replace function public.refresh_product_stats()
returns void language sql security definer set search_path = public as $$
  with last_d as (
    select product_id, max(collected_date) as ld from price_history group by product_id
  ),
  agg as (
    select h.product_id,
           min(h.sale_price)                                             as atl,
           count(*)                                                      as days,
           min(h.collected_date)                                         as first_date,
           (count(*) filter (where h.sale_price >= h.list_price * 0.98))::numeric
             / count(*)                                                  as lp_ratio,
           percentile_cont(0.5) within group (order by h.sale_price)
             filter (where h.collected_date > l.ld - 30)                 as base
    from price_history h
    join last_d l on l.product_id = h.product_id
    group by h.product_id, l.ld
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
           when c.real >= 0.10 or (c.current_price <= c.atl * 1.02 and c.real >= 0.03) then 'real'
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

-- ---------- 1. 시뮬레이터 상태 테이블 (웹에서는 접근 불가: RLS 켜고 정책 없음) ----------
create table if not exists public.sim_state (
  id        int primary key default 1 check (id = 1),
  anchor    date not null,                 -- sim_seed 를 실행한 날 (시나리오의 기준일, 바뀌지 않는다)
  last_date date not null,                 -- 가격을 마지막으로 만든 날 (하루 지나기를 누를 때마다 +1)
  seeded_at timestamptz not null default now()
);
create table if not exists public.sim_products (
  product_id bigint primary key references public.products(id) on delete cascade,
  scn        text not null check (scn in ('real','inflated','steady','flash')),
  seed       int  not null,
  market     int  not null,                -- 이 모델이 실제로 팔리는 가격
  true_model_id bigint references public.models(id) on delete cascade  -- 정답 모델 (AI 정규화 정확도를 채점할 때 쓴다)
);
alter table public.sim_state    enable row level security;
alter table public.sim_products enable row level security;

-- ---------- 2. 같은 입력이면 같은 값이 나오는 난수 (0 이상 1 미만) ----------
create or replace function public.sim_noise(a bigint, b bigint)
returns numeric language sql immutable as $$
  select (abs(hashtext(a::text || ':' || b::text)::bigint) % 10000) / 10000.0
$$;

-- ---------- 3. 가격 시나리오 ----------
-- p_d = 시뮬레이션 '오늘'(0)로부터 며칠 전인가. 음수는 앞으로 올 날짜(하루 지나기).
--   real      진짜 할인 : 한동안 정가 → 1차 할인(88%) → 본 할인(60~75%). 앞으로 최저가를 한 번 더 갱신
--   inflated  부풀림    : 정가를 1.8~2.4배로 부풀리고, 실제로는 늘 시장가 근처(±3%)에 팔린다
--   steady    보통      : 정가의 96.5~98.5% 사이에서 조금씩 흔들린다
--   flash     반짝 특가 : 평소엔 정가, 시뮬레이션 1~2일 뒤에 38% 특가
create or replace function public.sim_sale_price(p_scn text, p_seed int, p_d int, p_list int, p_market int)
returns int language plpgsql immutable as $$
declare
  n     numeric := sim_noise(p_seed, p_d);
  depth numeric := 0.60 + (p_seed % 16) / 100.0;   -- 본 할인 깊이: 정가의 60~75%
  p1    int     := 28 + (p_seed % 20);             -- 1차 할인 시작: 28~47일 전
  p2    int     := 5 + (p_seed % 10);              -- 본 할인 시작: 5~14일 전
  r     numeric;
begin
  if p_scn = 'inflated' then
    r := p_market * (0.97 + n * 0.06);
  elsif p_scn = 'steady' then
    r := p_list * (0.965 + n * 0.02);
  elsif p_scn = 'real' then
    r := p_list * case
           when p_d > p1  then 1.0
           when p_d > p2  then 0.88
           when p_d >= 0  then depth
           when p_d <= -(1 + p_seed % 4) then depth - 0.05
           else depth
         end;
  else
    r := p_list * case when p_d in (-1, -2) then 0.62 else 1.0 end;
  end if;
  return (round(r / 100) * 100)::int;
end $$;

-- ---------- 4. 데모 데이터 만들기 ----------
create or replace function public.sim_seed(p_days int default 90, p_reset boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_anchor date := current_date;
  v_models int; v_products int; v_rows int;
begin
  if exists (select 1 from products where is_demo) then
    if not p_reset then
      return '이미 데모 데이터가 있습니다. 처음부터 다시 만들려면: select sim_seed(90, true);';
    end if;
    delete from products where is_demo;          -- 가격 기록, 통계, 찜, 관심 상품, 알림도 함께 지워진다
    delete from models   where is_demo;
    delete from sim_state;
  end if;

  -- (1) 모델 목록: 품목 23종 x 색 3가지 = 69개 모델
  create temp table _sim_models on commit drop as
  with stems(idx, cat, ko, en, code, lo, hi, brands) as (values
    ( 1,'shoes','에어 러너','Air Runner','SH01', 89000,159000, array['STRIDEON','KICKLAB','TRAILHAUS']),
    ( 2,'shoes','클라우드 스니커','Cloud Sneaker','SH02', 99000,179000, array['KICKLAB','TRAILHAUS','STRIDEON']),
    ( 3,'shoes','트레일 하이커','Trail Hiker','SH03',119000,219000, array['TRAILHAUS','STRIDEON','KICKLAB']),
    ( 4,'shoes','코트 클래식','Court Classic','SH04', 79000,139000, array['STRIDEON','TRAILHAUS','KICKLAB']),
    ( 5,'shoes','캔버스 로우','Canvas Low','SH05', 59000,109000, array['KICKLAB','STRIDEON','TRAILHAUS']),
    ( 6,'shoes','칠 슬라이드','Chill Slide','SH06', 39000, 79000, array['TRAILHAUS','KICKLAB','STRIDEON']),
    ( 7,'top','오버핏 후드','Oversized Hoodie','TP01', 49000, 99000, array['BASIC FIT','MODERNE','LINENCO']),
    ( 8,'top','케이블 니트','Cable Knit','TP02', 69000,129000, array['MODERNE','LINENCO','BASIC FIT']),
    ( 9,'top','헤비 코튼 티','Heavy Cotton Tee','TP03', 29000, 59000, array['BASIC FIT','LINENCO','MODERNE']),
    (10,'top','옥스포드 셔츠','Oxford Shirt','TP04', 59000,109000, array['LINENCO','MODERNE','BASIC FIT']),
    (11,'top','기모 맨투맨','Fleece Sweatshirt','TP05', 45000, 89000, array['BASIC FIT','MODERNE','LINENCO']),
    (12,'top','스트라이프 롱슬리브','Stripe Long Sleeve','TP06', 39000, 79000, array['MODERNE','BASIC FIT','LINENCO']),
    (13,'bottom','와이드 데님','Wide Denim','BT01', 59000,119000, array['DENIMLAB','SLACKS ROOM','BASIC FIT']),
    (14,'bottom','원턱 슬랙스','One-tuck Slacks','BT02', 69000,129000, array['SLACKS ROOM','DENIMLAB','MODERNE']),
    (15,'bottom','카고 팬츠','Cargo Pants','BT03', 55000,109000, array['DENIMLAB','BASIC FIT','SLACKS ROOM']),
    (16,'bottom','조거 스웨트팬츠','Jogger Sweatpants','BT04', 39000, 79000, array['BASIC FIT','DENIMLAB','SLACKS ROOM']),
    (17,'bottom','코듀로이 팬츠','Corduroy Pants','BT05', 59000,109000, array['SLACKS ROOM','MODERNE','DENIMLAB']),
    (18,'outer','구스다운 숏패딩','Goose Down Short Puffer','OT01',189000,389000, array['NORTHLINE','PEAK&PINE','ATELIER K']),
    (19,'outer','캐시미어 코트','Cashmere Coat','OT02',289000,489000, array['ATELIER K','NORTHLINE','PEAK&PINE']),
    (20,'outer','윈드브레이커','Windbreaker','OT03', 89000,169000, array['PEAK&PINE','ATELIER K','NORTHLINE']),
    (21,'outer','울 블루종','Wool Blouson','OT04',149000,289000, array['ATELIER K','PEAK&PINE','NORTHLINE']),
    (22,'outer','플리스 자켓','Fleece Jacket','OT05', 79000,149000, array['NORTHLINE','ATELIER K','PEAK&PINE']),
    (23,'outer','트렌치 코트','Trench Coat','OT06',169000,329000, array['PEAK&PINE','NORTHLINE','ATELIER K'])
  ),
  colors(cidx, ko, en, code) as (values
    (1,'블랙','Black','BLK'),(2,'화이트','White','WHT'),(3,'네이비','Navy','NVY'),
    (4,'그레이','Grey','GRY'),(5,'베이지','Beige','BGE'),(6,'카키','Khaki','KHK')
  )
  select row_number() over (order by s.idx, c.cidx)::int                   as mid,
         s.cat, s.ko as stem_ko, s.en as stem_en, c.ko as col_ko, c.en as col_en,
         s.brands[1 + (s.idx + c.cidx) % 3]                                as brand,
         'DM-' || s.code || '-' || c.code                                  as style_code,
         (round((s.lo + sim_noise(s.idx * 10 + c.cidx, 7) * (s.hi - s.lo)) / 1000) * 1000)::int as market
  from stems s join colors c on (s.idx + c.cidx) % 2 = 0;

  insert into models (brand, model_name, style_code, category, is_demo)
  select brand, stem_ko || ' ' || col_ko, style_code, cat, true from _sim_models;
  get diagnostics v_models = row_count;

  -- (2) 상품 목록: 모델마다 가상 쇼핑몰 2~3곳(데모몰A/B/C)에 올린다
  create temp table _sim_products on commit drop as
  select x.*,
         case when x.r < 0.35 then 'real' when x.r < 0.60 then 'inflated'
              when x.r < 0.85 then 'steady' else 'flash' end as scn,
         0 as list
  from (
    select m.mid, k.k as pk, m.mid * 10 + k.k as seed, m.brand, m.cat, m.stem_ko, m.stem_en,
           m.col_ko, m.col_en, m.style_code, m.market, sim_noise(m.mid * 10 + k.k, 99) as r
    from _sim_models m cross join (values (1),(2),(3)) as k(k)
    where k.k = (m.mid % 3) + 1 or k.k = ((m.mid + 1) % 3) + 1 or sim_noise(m.mid, k.k) < 0.4
  ) x;

  update _sim_products set list = case scn
      when 'inflated' then round(market * (1.8 + sim_noise(seed, 5) * 0.6) / 1000) * 1000
      when 'steady'   then round(market * (1.0 + sim_noise(seed, 5) * 0.1) / 1000) * 1000
      else market end;

  -- 쇼핑몰마다 상품명 표기가 다르다. 데모몰C는 품번이 없어서 model_id 를 비워 둔다 (AI 정규화 대상)
  insert into products (platform, external_id, model_id, name, brand, category, list_price, current_price,
                        image_url, product_url, is_soldout, first_seen_at, last_seen_at, is_demo)
  select '데모몰' || chr(64 + p.pk),
         format('demo-%s-%s', p.pk, p.mid),
         case when p.pk = 3 then null else (select id from models where style_code = p.style_code) end,
         case p.pk
           when 1 then format('[%s] %s %s %s', p.brand, p.stem_ko, p.col_ko, p.style_code)
           when 2 then format('%s %s %s (%s)', p.brand, p.stem_en, p.col_en, p.style_code)
           else        format('%s %s %s', p.brand, p.stem_ko, upper(p.col_en))
         end,
         p.brand, p.cat, p.list, sim_sale_price(p.scn, p.seed, 0, p.list, p.market),
         null, format('https://example.com/demo/%s/%s', p.pk, p.mid),
         (p.seed % 23 = 0),
         now() - make_interval(days => p_days), now(), true
  from _sim_products p;
  get diagnostics v_products = row_count;

  insert into sim_products (product_id, scn, seed, market, true_model_id)
  select pr.id, p.scn, p.seed, p.market, (select id from models where style_code = p.style_code)
  from _sim_products p
  join products pr on pr.platform = '데모몰' || chr(64 + p.pk) and pr.external_id = format('demo-%s-%s', p.pk, p.mid);

  -- (3) 일별 가격 기록 (p_days 일, 오늘 포함)
  insert into price_history (product_id, collected_date, sale_price, list_price, is_soldout)
  select s.product_id, v_anchor - d, sim_sale_price(s.scn, s.seed, d, pr.list_price, s.market), pr.list_price, false
  from sim_products s
  join products pr on pr.id = s.product_id and pr.is_demo
  cross join generate_series(0, p_days - 1) as d;
  get diagnostics v_rows = row_count;

  insert into sim_state (id, anchor, last_date) values (1, v_anchor, v_anchor);
  perform refresh_product_stats();

  return format('데모 데이터 생성 완료: 모델 %s개, 상품 %s개, 가격 기록 %s건 (%s일)', v_models, v_products, v_rows, p_days);
end $$;

-- ---------- 5. 하루 지나기 (시연용) ----------
create or replace function public.sim_next_day()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_anchor date; v_last date; v_next date; v_rows int; v_lows int; v_notis int;
begin
  select anchor, last_date into v_anchor, v_last from sim_state;
  if v_anchor is null then
    raise exception '먼저 select sim_seed(); 를 실행하세요';
  end if;
  v_next := v_last + 1;                      -- 시나리오의 d 는 항상 기준일(anchor) 기준: 1일 뒤 = -1, 2일 뒤 = -2 ...

  insert into price_history (product_id, collected_date, sale_price, list_price, is_soldout)
  select s.product_id, v_next, sim_sale_price(s.scn, s.seed, v_anchor - v_next, p.list_price, s.market),
         p.list_price, p.is_soldout
  from sim_products s join products p on p.id = s.product_id;
  get diagnostics v_rows = row_count;

  update products p set current_price = h.sale_price, last_seen_at = now()
  from price_history h
  where h.product_id = p.id and h.collected_date = v_next and p.is_demo;

  update sim_state set last_date = v_next;
  perform refresh_product_stats();

  select count(*) into v_lows
  from product_stats s join products p on p.id = s.product_id
  where p.is_demo and s.is_new_low;
  v_notis := generate_notifications();

  return jsonb_build_object('date', v_next, 'products', v_rows, 'new_lows', v_lows, 'notifications', v_notis);
end $$;

-- ---------- 6. 실행 권한: 웹의 비로그인 사용자는 모두 막고, 하루 지나기만 로그인 사용자에게 연다 ----------
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.sim_seed(int, boolean)   from public, anon, authenticated;
    revoke all on function public.sim_next_day()           from public, anon, authenticated;
    revoke all on function public.refresh_product_stats()  from public, anon, authenticated;
    revoke all on function public.generate_notifications() from public, anon, authenticated;
    grant execute on function public.sim_next_day() to authenticated;
  end if;
end $$;
