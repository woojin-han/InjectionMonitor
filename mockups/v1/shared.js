/* 세일체크 목업 공통 데이터와 계산 (실제 서비스의 DB 계산식과 같은 규칙) */
(function () {
  const START = new Date('2026-11-14');
  const day = (i) => { const d = new Date(START); d.setDate(d.getDate() + i); return d; };
  const md = (d) => `${d.getMonth() + 1}/${d.getDate()}`;

  // 일별 판매가 배열 만들기: [[일수, 가격], ...] 구간
  const seq = (...parts) => parts.flatMap(([n, p]) => Array(n).fill(p));

  const RAW = [
    { id: 1, platform: '무신사', brand: 'NORTHLINE', name: '헤비 구스다운 숏패딩 자켓', cat: 'outer', emoji: '🧥', bg: '#2b2d42', list: 299000, h: seq([16, 119000]) },
    { id: 2, platform: '29CM', brand: 'NIKE', name: '에어포스 1 \'07 화이트 DD1391-100', cat: 'shoes', emoji: '👟', bg: '#dfe7ef', list: 139000, h: seq([12, 139000], [3, 109000], [1, 99000]), compare: [['29CM', 99000], ['무신사', 109000], ['브랜드몰', 139000]] },
    { id: 3, platform: '무신사', brand: 'adidas', name: '삼바 OG 블랙 B75807', cat: 'shoes', emoji: '👟', bg: '#e9e4da', list: 139000, h: seq([8, 125000], [8, 129000]) },
    { id: 4, platform: '무신사', brand: 'MODERNE', name: '울 블렌드 케이블 니트', cat: 'top', emoji: '🧶', bg: '#efe2d0', list: 89000, h: seq([16, 49000]) },
    { id: 5, platform: '29CM', brand: 'DENIMLAB', name: '와이드 스트레이트 데님 팬츠', cat: 'bottom', emoji: '👖', bg: '#d6e2f0', list: 79000, h: seq([10, 79000], [6, 59000]) },
    { id: 6, platform: '브랜드몰', brand: 'BASIC FIT', name: '오버핏 기모 후드 스웨트셔츠', cat: 'top', emoji: '👕', bg: '#e3e8e1', list: 69000, h: seq([5, 59000], [4, 55000], [6, 59000], [1, 57000]) },
    { id: 7, platform: '무신사', brand: 'New Balance', name: '530 화이트 실버 MR530SG', cat: 'shoes', emoji: '👟', bg: '#eceff3', list: 129000, h: seq([3, 99000]), offset: 13 },
    { id: 8, platform: '29CM', brand: 'ATELIER K', name: '캐시미어 블렌드 싱글 코트', cat: 'outer', emoji: '🧥', bg: '#d9cbbd', list: 259000, h: seq([9, 259000], [3, 207200], [3, 194250], [1, 181300]), soldoutNo: true },
  ];

  const median = (a) => { const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };

  function stats(p) {
    const h = p.h, cur = h[h.length - 1], off = p.offset || 0;
    const atl = Math.min(...h);
    const atlIdx = h.lastIndexOf(atl);
    const base = median(h.slice(-30));
    const disp = Math.max(0, (p.list - cur) / p.list);
    const real = (base - cur) / base;
    const lpDays = h.filter((x) => x >= p.list * 0.98).length;
    const ratio = lpDays / h.length;
    let grade;
    if (h.length < 7) grade = 'insufficient';
    else if (disp >= 0.3 && ratio < 0.1 && real < 0.05) grade = 'inflated';
    else if (real >= 0.1 || (cur <= atl * 1.02 && cur < base)) grade = 'real';
    else grade = 'normal';
    const prev = h.length > 1 ? h[h.length - 2] : cur;
    return {
      cur, atl, atlDate: md(day(off + atlIdx)), base, disp, real, lpDays, days: h.length, ratio, grade,
      isAtl: cur <= atl, change: cur - prev, since: md(day(off)),
      dates: h.map((_, i) => md(day(off + i))),
    };
  }

  const GRADE = {
    real: { label: '진짜 할인', sym: '✓', cls: 'g-real' },
    normal: { label: '보통', sym: '–', cls: 'g-normal' },
    inflated: { label: '부풀림 의심', sym: '!', cls: 'g-inflated' },
    insufficient: { label: '데이터 부족', sym: '⋯', cls: 'g-insufficient' },
  };

  function verdict(p, s) {
    if (s.grade === 'insufficient') return `수집 ${s.days}일째예요. 판단하려면 최소 7일이 필요해요.`;
    if (s.grade === 'inflated') return `${s.days}일 동안 정가(${won(p.list)})로 팔린 날이 ${s.lpDays}일이에요. ${pct(s.disp)} 할인은 사실상 평소 가격이에요.`;
    if (s.grade === 'real') return s.isAtl ? `평소(${won(s.base)})보다 ${pct(s.real)} 싸고, 수집 이후 역대 최저가예요.` : `평소(${won(s.base)})보다 ${pct(s.real)} 싸요.`;
    return `평소 가격(${won(s.base)})과 비슷해요. 급하지 않다면 기다려 보세요.`;
  }

  const AI = {
    1: '정가로 팔린 기록이 없어 60% 할인은 실제 할인이 아니에요. 가격이 내려갈 때 알림을 받아 보세요.',
    2: '12일간 정가였다가 처음 내려간 가격이에요. 3개 플랫폼 중 가장 싸니 지금 사기 좋아요.',
    3: '11월 초 125,000원까지 내려갔다가 다시 올랐어요. 125,000원으로 목표가를 걸어 두세요.',
    4: '정가 판매 기록이 없는 상시 할인 상품이에요. 표시 할인율은 무시하세요.',
    5: '정가에서 25% 내려간 실제 할인이에요. 역대 최저가와 같아요.',
    6: '55,000~59,000원 사이를 오가요. 역대 최저가 55,000원으로 목표가를 걸어 두세요.',
    7: '수집한 지 3일이라 아직 판단하기 일러요.',
    8: '세 번째 가격 인하로 역대 최저가예요. 평소보다 30% 싸요.',
  };

  const won = (n) => Math.round(n).toLocaleString('ko-KR') + '원';
  const pct = (r) => Math.round(r * 100) + '%';

  /* SVG 가격 그래프. 색은 CSS 변수(--c-line, --c-list, --c-low, --c-grid, --c-text)로 받는다 */
  function chart(p, s, { w = 640, h = 220, pad = 36 } = {}) {
    const vals = [...p.h, p.list];
    const max = Math.max(...vals) * 1.05, min = Math.min(...p.h) * 0.85;
    const n = p.h.length;
    const x = (i) => pad + (n === 1 ? 0 : (i / (n - 1)) * (w - pad * 1.5));
    const y = (v) => 10 + (1 - (v - min) / (max - min)) * (h - pad - 10);
    const pts = p.h.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' ');
    // 계단식 (가격은 하루 단위로 바뀐다)
    let step = `M${x(0)},${y(p.h[0])}`;
    for (let i = 1; i < n; i++) step += ` H${x(i).toFixed(1)} V${y(p.h[i]).toFixed(1)}`;
    const ticks = [min + (max - min) * 0.15, (min + max) / 2, max * 0.97];
    const ai = p.h.lastIndexOf(s.atl);
    const area = `${step} V${h - pad} H${x(0)} Z`;
    return `<svg viewBox="0 0 ${w} ${h}" class="chart" role="img" aria-label="${p.name} 가격 그래프">
      <defs><linearGradient id="fill${p.id}" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="var(--c-line)" stop-opacity=".22"/><stop offset="1" stop-color="var(--c-line)" stop-opacity="0"/></linearGradient></defs>
      ${ticks.map((t) => `<line x1="${pad}" x2="${w - pad / 2}" y1="${y(t)}" y2="${y(t)}" stroke="var(--c-grid)"/><text x="${pad - 6}" y="${y(t) + 4}" text-anchor="end" font-size="10" fill="var(--c-text)">${Math.round(t / 1000)}k</text>`).join('')}
      <line x1="${pad}" x2="${w - pad / 2}" y1="${y(p.list)}" y2="${y(p.list)}" stroke="var(--c-list)" stroke-dasharray="5 4" stroke-width="1.5"/>
      <text x="${w - pad / 2}" y="${y(p.list) - 6}" text-anchor="end" font-size="11" fill="var(--c-list)">정가 ${won(p.list)}</text>
      <path d="${area}" fill="url(#fill${p.id})"/>
      <path d="${step}" fill="none" stroke="var(--c-line)" stroke-width="2.5" stroke-linejoin="round"/>
      <circle cx="${x(ai)}" cy="${y(s.atl)}" r="5" fill="var(--c-low)" stroke="var(--c-bg, #fff)" stroke-width="2"/>
      <text x="${Math.min(x(ai), w - 90)}" y="${y(s.atl) - 12}" font-size="11" fill="var(--c-low)" font-weight="700">★ 최저 ${won(s.atl)}</text>
      ${[0, Math.floor((n - 1) / 2), n - 1].filter((v, i, a) => a.indexOf(v) === i).map((i) => `<text x="${x(i)}" y="${h - pad + 16}" text-anchor="middle" font-size="10" fill="var(--c-text)">${s.dates[i]}</text>`).join('')}
    </svg>`;
  }

  const products = RAW.map((p) => ({ ...p, s: stats(p), ai: AI[p.id] }));
  products.forEach((p) => (p.verdict = verdict(p, p.s)));

  const NOTIS = [
    { pid: 2, type: 'target', msg: '에어포스 1 \'07 가격이 99,000원으로 내려가 목표가 100,000원 이하가 되었어요', time: '2시간 전', unread: true },
    { pid: 8, type: 'low', msg: '캐시미어 블렌드 싱글 코트 가격이 역대 최저가 181,300원을 기록했어요', time: '2시간 전', unread: true },
    { pid: 5, type: 'low', msg: '와이드 스트레이트 데님 팬츠 가격이 역대 최저가 59,000원을 기록했어요', time: '어제', unread: false },
  ];

  window.SC = { products, GRADE, NOTIS, won, pct, chart, CAT: { all: '전체', shoes: '신발', top: '상의', bottom: '하의', outer: '아우터' } };
})();
