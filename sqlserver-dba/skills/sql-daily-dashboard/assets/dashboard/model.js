/*  model.js - builds the view model every dashboard design renders, from the collector JSON (Build-Dashboard.ps1).
    No DOM access here: the page calls DashModel.build(raw) once and draws from the result.

    Windows: c = today (local midnight to the last complete hour), a = the same hours 7 days ago,
             b = the same hours on the baseline day. CPU is in CPU-minutes; "cores" = CPU-minutes / minutes in window;
             % of server = cores / logical CPUs (meta.cpu_count) x 100.

    model = {
      meta:      { title, server, environment, generated, baselineDate, baselineNote, hours, day_c, day_a, day_b, cpu_count, thresholds },
      health:    [{ area, value, status: 'ok'|'warn'|'alert', note }]          server checks, worst first
      server:    raw server snapshot (instance, cpu[], rates, memory, workers, ag[], volumes[], io[], log, blocking, ...)
      meter:     [{ h, sql, total, n }]  the CPU meter averaged per hour of today (only the hours the ring buffer still holds)
      dbs:       [{ name, meta, totals:{c,a,b}, hourly[], groups[], objects[], top[], opportunities[], movers[],
                    movers_by_object[], waits:{categories[], parallel_objects[]}, daily[], projection }]
                 objects carry flags[], reasons[], worsening, stage ('bubbling'|'untracked'|'open'|'ready'|'watch'|'done'),
                 candidate, owner, score, hourly[], stmts[]
      business:  [{ key, label, good, group, hourly:[{h,c,a}], total_c, total_a }]   group = the workload group it belongs to
      candidates:[{ status, item, keys[], fields[], seen:{db, obj, cpu_c} | null }]
    }
*/
(function (root) {
  'use strict';

  var DEFAULTS = {
    cpuPctWarn: 60, cpuPctAlert: 80,
    risingRatio: 1.5, risingMinCpuMin: 10,
    regressionRatio: 2.0, regressionMinCpuMin: 5,
    callRateRatio: 2.0,
    qsPctWarn: 80, qsPctAlert: 90,
    compilesWarn: 100,
    errorsJumpRatio: 1.3, errorsMin: 100,
    diskFreePctWarn: 15, diskFreePctAlert: 8,
    logBackupMinWarn: 30
  };

  function num(v) { return (v === null || v === undefined || isNaN(v)) ? 0 : Number(v); }
  function ratio(c, a) { return a > 0 ? c / a : (c > 0 ? Infinity : 1); }
  function pct(c, a) { return a > 0 ? 100 * (c - a) / a : null; }
  function win(row) { return { cpu_min: num(row && row.cpu_min), execs: num(row && row.execs), reads: num(row && row.reads),
                               dur_min: num(row && row.dur_min), timeouts: num(row && row.timeouts), errors: num(row && row.errors) }; }
  function perExec(w) {
    w.cpu_ms = w.execs > 0 ? 60000 * w.cpu_min / w.execs : null;
    w.dur_ms = w.execs > 0 ? 60000 * w.dur_min / w.execs : null;
    w.reads_per = w.execs > 0 ? w.reads / w.execs : null;
    w.reads_gb = w.reads * 8 / 1048576;
    return w;
  }

  // ---- candidates (known-candidates.md) ----------------------------------------------------------------------
  var STATUS_RANK = { ready: 3, open: 2, done: 1 };
  function keyMatches(key, o) {
    if (!key) return false;
    var k = key.trim();
    if (/^0x[0-9a-f]{16}$/i.test(k)) return !!o.qhash && o.qhash.toUpperCase() === k.toUpperCase();
    if (/[^A-Za-z0-9_.\[\]*]/.test(k)) return false;                      // paths, prose, settings
    var re = new RegExp('^' + k.replace(/[.\[\]]/g, function (ch) { return '\\' + ch; }).replace(/\*/g, '.*') + '$', 'i');
    return re.test(o.obj) || re.test(o.nm) || re.test((o.sch || '') + '.' + o.nm);
  }
  function findCandidate(cands, o) {
    var best = null;
    for (var i = 0; i < cands.length; i++) {
      var c = cands[i];
      for (var j = 0; j < (c.keys || []).length; j++) {
        if (keyMatches(c.keys[j], o)) {
          if (!best || (STATUS_RANK[c.status] || 0) > (STATUS_RANK[best.status] || 0)) best = c;
          break;
        }
      }
    }
    return best;
  }

  // ---- one database --------------------------------------------------------------------------------------------
  function buildDb(d, cands, th, topN) {
    var meta = d.meta || {};
    var hours = num(meta.hours) || 1;
    var core = d.core || [];
    var db = { name: meta.db, meta: meta, totals: { c: win(), a: win(), b: win() }, hourly: [], groups: [], objects: [],
               top: [], opportunities: [], movers: [],
               waits: (Array.isArray(d.waits) ? d.waits[0] : d.waits) || { categories: [], parallel_objects: [] },   // FOR JSON ROOT wraps it in an array
               daily: d.daily || [] };

    var hourMap = {}, grpMap = {}, objMap = {};
    function hourRow(h) { return hourMap[h] || (hourMap[h] = { h: h, c: win(), a: win(), b: win() }); }
    function grpRow(g) { return grpMap[g] || (grpMap[g] = { grp: g, c: win(), a: win(), b: win(), hourly: {} }); }

    core.forEach(function (r) {
      var w = (r.win || '').toLowerCase();
      if (r.s === 'h') {
        hourRow(r.h)[w] = win(r);
        var t = db.totals[w];
        ['cpu_min', 'execs', 'reads', 'dur_min', 'timeouts', 'errors'].forEach(function (k) { t[k] += num(r[k]); });
      } else if (r.s === 'g') {
        grpRow(r.grp)[w] = win(r);
      } else if (r.s === 'gh') {
        var g = grpRow(r.grp); var hh = g.hourly[r.h] || (g.hourly[r.h] = { h: r.h, c: 0, a: 0 });
        hh[w] = num(r.cpu_min);
      } else if (r.s === 'o') {
        var o = objMap[r.obj] || (objMap[r.obj] = { obj: r.obj, grp: r.grp, kind: r.kind, sch: r.sch, nm: r.nm, qhash: r.qhash || null,
                                                     c: win(), a: win(), b: win(), hourly: [], stmts: [] });
        o[w] = win(r);
      }
    });
    core.forEach(function (r) {
      if (r.s === 'oh' && objMap[r.obj]) objMap[r.obj].hourly.push({ h: r.h, cpu_min: num(r.cpu_min), execs: num(r.execs) });
    });
    (d.stmts || []).forEach(function (s) { if (objMap[s.obj]) objMap[s.obj].stmts.push(s); });

    // totals and per-window derived values
    ['c', 'a', 'b'].forEach(function (k) {
      var t = perExec(db.totals[k]);
      t.cores = t.cpu_min / (hours * 60);
    });
    db.hourly = Object.keys(hourMap).map(function (h) { return hourMap[h]; }).sort(function (x, y) { return x.h - y.h; });
    db.groups = Object.keys(grpMap).map(function (g) {
      var r = grpMap[g];
      r.hourly = Object.keys(r.hourly).map(function (h) { return r.hourly[h]; }).sort(function (x, y) { return x.h - y.h; });
      ['c', 'a', 'b'].forEach(function (k) { perExec(r[k]); });
      r.delta_pct = pct(r.c.cpu_min, r.a.cpu_min);
      r.share_pct = db.totals.c.cpu_min > 0 ? 100 * r.c.cpu_min / db.totals.c.cpu_min : 0;
      return r;
    }).sort(function (x, y) { return y.c.cpu_min - x.c.cpu_min; });

    // objects: ranks, flags, candidate status, score
    var objs = Object.keys(objMap).map(function (k) { return objMap[k]; });
    objs.forEach(function (o) { ['c', 'a', 'b'].forEach(function (k) { perExec(o[k]); }); o.hourly.sort(function (x, y) { return x.h - y.h; }); });
    objs.sort(function (x, y) { return y.a.cpu_min - x.a.cpu_min; }).forEach(function (o, i) { o.rank_a = o.a.cpu_min > 0 ? i + 1 : null; });
    objs.sort(function (x, y) { return y.c.cpu_min - x.c.cpu_min; }).forEach(function (o, i) { o.rank_c = o.c.cpu_min > 0 ? i + 1 : null; });

    objs.forEach(function (o) {
      o.share_pct = db.totals.c.cpu_min > 0 ? 100 * o.c.cpu_min / db.totals.c.cpu_min : 0;
      o.delta_cpu_min = o.c.cpu_min - o.a.cpu_min;
      o.delta_pct = pct(o.c.cpu_min, o.a.cpu_min);
      o.stmts.sort(function (x, y) { return num(y.cpu_c) - num(x.cpu_c); });
      o.max_plans = o.stmts.reduce(function (m, s) { return Math.max(m, num(s.plans_c)); }, 0);
      o.candidate = findCandidate(cands, o);
      if (o.candidate && !o.candidate.seen) o.candidate.seen = { db: db.name, obj: o.obj, cpu_c: o.c.cpu_min };

      var f = [], why = [];
      if (!o.candidate && o.rank_c && o.rank_c <= topN) { f.push('untracked'); why.push('in today\'s top ' + topN + ' and not on the candidate list'); }
      if (o.rank_c && o.rank_c <= topN && (!o.rank_a || o.rank_a > topN)) { f.push('new-entrant'); why.push('top ' + topN + ' today, ' + (o.rank_a ? '#' + o.rank_a : 'absent') + ' a week ago'); }
      if (o.c.cpu_min >= th.risingMinCpuMin + o.a.cpu_min && ratio(o.c.cpu_min, o.a.cpu_min) >= th.risingRatio) { f.push('rising'); why.push(o.a.cpu_min > 0 ? 'CPU ' + fmtRatio(o.c.cpu_min, o.a.cpu_min) + ' a week ago' : 'no CPU a week ago'); }
      if (o.c.cpu_ms && o.a.cpu_ms && o.c.cpu_min >= th.regressionMinCpuMin && o.c.cpu_ms >= th.regressionRatio * o.a.cpu_ms) { f.push('slower'); why.push('CPU per execution ' + fmtRatio(o.c.cpu_ms, o.a.cpu_ms)); }
      if (o.a.execs > 0 && o.c.execs >= th.callRateRatio * o.a.execs && o.c.cpu_min >= th.regressionMinCpuMin) { f.push('more-calls'); why.push('executions ' + fmtRatio(o.c.execs, o.a.execs)); }
      if (o.c.timeouts > 0 && o.c.timeouts > o.a.timeouts) { f.push('timeouts'); why.push(o.c.timeouts + ' timeouts (' + o.a.timeouts + ' a week ago)'); }
      if (o.c.errors >= th.errorsMin && o.c.errors >= th.errorsJumpRatio * Math.max(1, o.a.errors)) { f.push('errors'); why.push(o.c.errors + ' errors (' + o.a.errors + ' a week ago)'); }
      if (o.max_plans >= 3) { f.push('many-plans'); why.push(o.max_plans + ' plans for one statement today'); }
      o.flags = f; o.reasons = why;
      // worsening = a signal that it got worse than a week ago; stage = where it sits in the optimization pipeline
      o.worsening = ['rising', 'slower', 'more-calls', 'timeouts', 'errors'].some(function (x) { return f.indexOf(x) >= 0; });
      o.stage = o.candidate ? (o.candidate.status === 'done' ? (o.worsening ? 'watch' : 'done') : o.candidate.status)
                            : (o.worsening || f.indexOf('new-entrant') >= 0 ? 'bubbling' : 'untracked');
      o.owner = null;
      (o.candidate && o.candidate.fields || []).forEach(function (fl) { if (/^owner$/i.test(fl.name) && fl.value && fl.value !== '—' && fl.value !== '-') o.owner = fl.value; });

      // score: today's CPU, weighted up for signals that it is getting worse or nobody owns it yet; done items only
      // count when they show a signal again. Being big and untracked alone is a small nudge, not an alarm.
      var w = 1 + (f.indexOf('rising') >= 0 ? 0.5 : 0) + (f.indexOf('slower') >= 0 ? 0.5 : 0) + (f.indexOf('more-calls') >= 0 ? 0.25 : 0)
                + (f.indexOf('untracked') >= 0 ? 0.25 : 0) + (f.indexOf('new-entrant') >= 0 ? 0.25 : 0)
                + (f.indexOf('timeouts') >= 0 ? 0.25 : 0) + (f.indexOf('errors') >= 0 ? 0.25 : 0);
      if (o.candidate && o.candidate.status === 'done' && f.indexOf('rising') < 0 && f.indexOf('slower') < 0) w = 0;
      o.score = o.c.cpu_min * w;
    });
    db.objects = objs;
    db.top = objs.filter(function (o) { return o.rank_c && o.rank_c <= topN; });
    db.opportunities = objs.filter(function (o) { return o.score > 0 && (o.flags.length || (o.candidate && o.candidate.status !== 'done')); })
                           .sort(function (x, y) { return y.score - x.score; }).slice(0, 15);

    // statement movers vs a week ago
    db.movers = (d.stmts || []).map(function (s) {
      var c = num(s.cpu_c), a = num(s.cpu_a);
      return { obj: s.obj, query_id: s.query_id, query_hash: s.query_hash, cpu_c: c, cpu_a: a, delta: c - a,
               cpu_ms_c: s.cpu_ms_c, cpu_ms_a: s.cpu_ms_a, execs_c: s.execs_c, execs_a: s.execs_a,
               plans_c: s.plans_c, sql_text: s.sql_text,
               kind: a === 0 ? 'new' : c === 0 ? 'gone' : c > a ? 'up' : 'down' };
    }).filter(function (m) { return Math.abs(m.delta) >= 5; })
      .sort(function (x, y) { return Math.abs(y.delta) - Math.abs(x.delta); }).slice(0, 20);
    // A rewrite (vendor upgrade, hot-fix) gives statements new hashes: the object shows a "gone" and a "new" statement of
    // similar size. Mark those as replaced and give the net change per object, so totals aren't inflated.
    var byObj = {};
    db.movers.forEach(function (m) {
      var b = byObj[m.obj] || (byObj[m.obj] = { obj: m.obj, delta: 0, up: 0, down: 0, kinds: {} });
      b.delta += m.delta; b.kinds[m.kind] = true;
      if (m.delta > 0) b.up += m.delta; else b.down += m.delta;
    });
    db.movers.forEach(function (m) { if (byObj[m.obj].kinds['new'] && byObj[m.obj].kinds['gone']) m.replaced = true; });
    db.movers_by_object = Object.keys(byObj).map(function (k) {
      var b = byObj[k];
      return { obj: b.obj, delta: b.delta, up: b.up, down: b.down, replaced: !!(b.kinds['new'] && b.kinds['gone']) };
    }).sort(function (x, y) { return Math.abs(y.delta) - Math.abs(x.delta); });

    // projection: today's whole day at the same ratio to a week ago, using last week's whole day
    var dayA = (db.daily || []).filter(function (r) { return r.day === meta.day_a; })[0];
    db.projection = dayA && db.totals.a.cpu_min > 0
      ? { day_a_cpu_min: num(dayA.cpu_min), cpu_min: num(dayA.cpu_min) * db.totals.c.cpu_min / db.totals.a.cpu_min }
      : null;
    return db;
  }

  function fmtRatio(c, a) {
    if (!(a > 0)) return 'new (none a week ago)';
    var r = c / a;
    return (r >= 10 ? Math.round(r) : r.toFixed(1)) + '×';
  }

  // ---- server checks ----------------------------------------------------------------------------------------------
  function buildHealth(s, th, dbs) {
    var out = [];
    function add(area, value, status, note) { out.push({ area: area, value: value, status: status, note: note || '' }); }
    if (!s) return out;
    var cpu = s.cpu || [];
    var last = cpu.slice(-60);
    if (last.length) {
      var avg = last.reduce(function (m, r) { return m + num(r.sql_cpu); }, 0) / last.length;
      var mx = last.reduce(function (m, r) { return Math.max(m, num(r.sql_cpu)); }, 0);
      add('CPU (last hour)', Math.round(avg) + '% avg, ' + mx + '% peak', avg >= th.cpuPctAlert ? 'alert' : avg >= th.cpuPctWarn ? 'warn' : 'ok', 'SQL Server process, ring buffer');
    }
    if (s.memory) {
      var m = s.memory;
      add('Memory', num(m.sql_mem_gb) + ' GB in use, PLE ' + num(m.ple_s).toLocaleString() + ' s',
          m.memory_low || num(m.grants_pending) > 0 ? 'alert' : num(m.ple_s) < 300 ? 'warn' : 'ok',
          num(m.grants_pending) + ' grants pending; ' + num(m.adhoc_plan_cache_gb) + ' GB ad hoc plan cache');
    }
    if (s.workers) {
      var w = s.workers;
      // Two different counters: work_queue_count = tasks queued on a scheduler for a worker; THREADPOOL waits = tasks that
      // could not get a worker thread at all. A short THREADPOOL burst with an empty queue is a spike, not a backlog.
      add('Worker threads', num(w.workers) + ' of ' + num(w.max_workers) + ' workers in use',
          num(w.queued) > 0 || num(w.threadpool_waiting_now) > 5 ? 'alert' : num(w.workers) > 0.85 * num(w.max_workers) || num(w.threadpool_waiting_now) > 0 ? 'warn' : 'ok',
          num(w.threadpool_waiting_now) + ' tasks waiting for a thread (THREADPOOL) at sample time; ' + num(w.queued) + ' queued on schedulers; ' +
          num(w.threadpool_waits_since_restart).toLocaleString() + ' THREADPOOL waits since restart');
    }
    if (s.rates) {
      add('Compiles', num(s.rates.compiles) + '/s (' + num(s.rates.recompiles) + ' recompiles/s)',
          num(s.rates.compiles) >= th.compilesWarn ? 'warn' : 'ok', num(s.rates.batch_requests) + ' batches/s, ' + num(s.rates.seconds) + ' s sample');
    }
    if (s.blocking) {
      add('Blocking', num(s.blocking.blocked_now) + ' blocked now', num(s.blocking.blocked_now) > 5 || num(s.blocking.max_wait_s) > 30 ? 'alert' : num(s.blocking.blocked_now) > 0 ? 'warn' : 'ok',
          'longest wait ' + num(s.blocking.max_wait_s) + ' s');
    }
    if (s.long_running) {
      add('Long-running requests', (s.long_running.length || 0) + ' over 60 s', (s.long_running.length || 0) > 3 ? 'warn' : 'ok', '');
    }
    (s.ag || []).forEach(function (r) {
      if (r.is_primary) return;
      add('AG ' + r.replica, r.sync_state + ', redo ' + num(r.redo_queue_kb).toLocaleString() + ' KB',
          r.health !== 'HEALTHY' ? 'alert' : num(r.redo_queue_kb) > 1048576 ? 'warn' : 'ok', r.db);
    });
    (s.volumes || []).forEach(function (v) {
      add('Disk ' + v.volume, num(v.free_pct) + '% free (' + num(v.free_gb) + ' GB)',
          num(v.free_pct) < th.diskFreePctAlert ? 'alert' : num(v.free_pct) < th.diskFreePctWarn ? 'warn' : 'ok', '');
    });
    if (s.log && s.log.last_log_backup) {
      var ageMin = (new Date(s.instance.now_local) - new Date(s.log.last_log_backup)) / 60000;
      add('Transaction log', 'last log copy ' + Math.round(ageMin) + ' min ago', ageMin > 2 * th.logBackupMinWarn ? 'alert' : ageMin > th.logBackupMinWarn ? 'warn' : 'ok',
          s.log.holdup && s.log.holdup !== 'NOTHING' ? 'holdup: ' + s.log.holdup : '');
    }
    dbs.forEach(function (d) {
      var mm = d.meta || {};
      if (!mm.qs_max_mb) return;
      var p = 100 * num(mm.qs_used_mb) / num(mm.qs_max_mb);
      add('Query Store ' + mm.db, Math.round(p) + '% full (' + num(mm.qs_used_mb) + ' of ' + num(mm.qs_max_mb) + ' MB)',
          mm.qs_state !== 'READ_WRITE' || p >= th.qsPctAlert ? 'alert' : p >= th.qsPctWarn ? 'warn' : 'ok', mm.qs_state);
    });
    var order = { alert: 0, warn: 1, ok: 2 };
    return out.sort(function (x, y) { return order[x.status] - order[y.status]; });
  }

  // ---- business throughput ----------------------------------------------------------------------------------------
  function buildBusiness(b) {
    if (!b || !b.metrics) return [];
    return b.metrics.map(function (m) {
      var rows = (b.hourly || []).filter(function (r) { return r.metric === m.key; })
                                 .map(function (r) { return { h: r.h, c: num(r.c), a: num(r.a) }; })
                                 .sort(function (x, y) { return x.h - y.h; });
      return { key: m.key, label: m.label, good: m.good, group: m.group || null, hourly: rows,
               total_c: rows.reduce(function (s, r) { return s + r.c; }, 0),
               total_a: rows.reduce(function (s, r) { return s + r.a; }, 0) };
    });
  }

  function build(raw) {
    var meta = raw.meta || {};
    var th = {}, k;
    for (k in DEFAULTS) th[k] = DEFAULTS[k];
    for (k in (meta.thresholds || {})) th[k] = meta.thresholds[k];
    var topN = num(meta.topN) || 30;
    var cands = (raw.candidates || []).map(function (c) { var x = {}; for (var p in c) x[p] = c[p]; x.seen = null; return x; });
    var dbs = (raw.databases || []).map(function (d) { return buildDb(d, cands, th, topN); });
    var m0 = (dbs[0] && dbs[0].meta) || {};
    var srv = raw.server || {};
    return {
      meta: { title: meta.title || 'SQL Server daily workload', server: meta.server, environment: meta.environment,
              generated: meta.generated, baselineDate: meta.baselineDate, baselineNote: meta.baselineNote,
              hours: m0.hours, day_c: m0.day_c, day_a: m0.day_a, day_b: m0.day_b, utc_offset_min: m0.utc_offset_min,
              cpu_count: num(srv.instance && srv.instance.cpu_count) || null,
              topN: topN, thresholds: th, drill: meta.drill || {} },
      health: buildHealth(raw.server, th, dbs),
      server: srv,
      meter: buildMeter(srv.cpu, m0.day_c, m0.hours),
      dbs: dbs,
      business: buildBusiness(raw.extra && raw.extra.business),
      candidates: cands
    };
  }

  // The CPU meter (scheduler-monitor ring buffer, about 4 hours, one sample a minute) averaged per local hour of today,
  // within the dashboard's window. sql = the SQL Server process, all databases and background work; total = the whole machine.
  function buildMeter(samples, day, hours) {
    var by = {};
    (samples || []).forEach(function (s) {
      var t = String(s.t || '');
      if (t.slice(0, 10) !== day) return;
      var h = parseInt(t.slice(11, 13), 10);
      if (!(h >= 0 && h < hours)) return;
      var b = by[h] || (by[h] = { h: h, sql: 0, total: 0, n: 0 });
      b.sql += num(s.sql_cpu); b.total += num(s.total_cpu); b.n++;
    });
    return Object.keys(by).map(function (k) { var b = by[k]; return { h: b.h, sql: b.sql / b.n, total: b.total / b.n, n: b.n }; })
      .sort(function (x, y) { return x.h - y.h; });
  }

  // CPU-minutes as a share of the server: CPU-min ÷ (logical CPUs × minutes in the span) × 100. Query Store CPU is
  // worker time, so a parallel query counts every thread, as the CPU meter does.
  function pctOfServer(cpuMin, minutes, cpus) { return cpus > 0 && minutes > 0 ? 100 * cpuMin / (cpus * minutes) : null; }

  // A ready-to-paste request for Claude (with the sqlserver-performance-analysis skill) to profile one object.
  function drillPrompt(model, db, o) {
    var m = model.meta;
    var p = pctOfServer(o.c.cpu_min, m.hours * 60, m.cpu_count);
    var lines = [
      'Use the ' + (m.drill.skill || 'sqlserver-performance-analysis') + ' skill to profile ' + (o.kind === 'adhoc' ? 'ad hoc query_hash ' + o.qhash : o.obj) +
        ' in ' + db.name + ' on ' + m.server + ' (read-only).',
      'Dashboard ' + m.day_c + ', 00:00-' + pad(m.hours) + ':00: ' + o.c.cpu_min.toFixed(1) + ' CPU-min today' +
        (p === null ? '' : ' (' + (p < 0.1 ? p.toFixed(3) : p.toFixed(2)) + '% of the server\'s ' + m.cpu_count + ' CPUs)') + ' vs ' + o.a.cpu_min.toFixed(1) +
        ' on ' + m.day_a + ' and ' + o.b.cpu_min.toFixed(1) + ' on the baseline ' + m.day_b + '; ' + o.c.execs.toLocaleString() + ' executions, ' +
        (o.c.cpu_ms === null ? '-' : o.c.cpu_ms.toFixed(1)) + ' ms CPU and ' + (o.c.reads_per === null ? '-' : Math.round(o.c.reads_per).toLocaleString()) + ' reads each.',
      o.reasons.length ? 'Signals: ' + o.reasons.join('; ') + '.' : '',
      o.stmts.length ? 'Top statement query_id ' + o.stmts.map(function (s) { return s.query_id; }).slice(0, 3).join(', ') + '.' : '',
      o.candidate ? 'Already on the candidate list (' + o.candidate.status + '): ' + o.candidate.item.replace(/`/g, '') : 'Not on the candidate list yet.',
      'Find the statement and plan operator that cost the time, say who sends it, and propose the smallest fix with a parity test.'
    ];
    return lines.filter(Boolean).join('\n');
  }
  function pad(h) { return (h < 10 ? '0' : '') + h; }

  // EDIT ME values for the skill's scripts, so the drill-down can show what to paste.
  function scriptParams(o) {
    var ids = o.stmts.map(function (s) { return s.query_id; }).slice(0, 5).join(',');
    return [
      { script: '05_qs_object_profile.sql', edit: o.kind === 'adhoc' ? null : "@Object = N'" + o.obj + "'" },
      { script: '06_plan_operators.sql', edit: ids ? "@QueryIds = '" + ids + "'" : null },
      { script: '08_who_runs_it.sql', edit: o.kind === 'adhoc' ? "@QueryHash = " + o.qhash : "@Object = N'" + o.obj + "'" },
      { script: '09_errors_timeouts.sql', edit: (o.c.errors || o.c.timeouts) ? "@Object = N'" + o.obj + "'" : null }
    ].filter(function (x) { return x.edit; });
  }

  root.DashModel = { build: build, drillPrompt: drillPrompt, scriptParams: scriptParams, fmtRatio: fmtRatio, pctOfServer: pctOfServer, DEFAULTS: DEFAULTS };
})(typeof window !== 'undefined' ? window : this);
