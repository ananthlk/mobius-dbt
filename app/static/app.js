(function () {
  const RUN_NOW_BTN = document.getElementById('run-now');
  const RUN_FEEDBACK = document.getElementById('run-feedback');
  const RUNS_TBODY = document.querySelector('#runs-table tbody');
  const DETAIL_SECTION = document.getElementById('detail-section');
  const DETAIL_BODY = document.getElementById('detail-body');
  const DETAIL_CLOSE = document.getElementById('detail-close');

  const REFRESH_INTERVAL_MS = 5000;
  let refreshTimer = null;

  function setFeedback(text, isError) {
    RUN_FEEDBACK.textContent = text;
    RUN_FEEDBACK.className = 'feedback' + (isError ? ' error' : text ? ' success' : '');
  }

  function formatDate(iso) {
    if (!iso) return '—';
    try {
      const d = new Date(iso);
      return d.toLocaleString();
    } catch (_) {
      return iso;
    }
  }

  function shortId(runId) {
    if (!runId || runId.length < 8) return runId || '—';
    return runId.slice(0, 8) + '…';
  }

  function renderRuns(runs) {
    if (!RUNS_TBODY) return;
    RUNS_TBODY.innerHTML = runs.length === 0
      ? '<tr><td colspan="9">No runs yet.</td></tr>'
      : runs.map(function (r) {
          const statusClass = r.status === 'running' ? 'status-running' : r.status === 'success' ? 'status-success' : 'status-failure';
          return (
            '<tr>' +
            '<td>' + shortId(r.run_id) + '</td>' +
            '<td>' + (r.origin || '—') + '</td>' +
            '<td>' + (r.destination || '—') + '</td>' +
            '<td>' + formatDate(r.started_at) + '</td>' +
            '<td class="' + statusClass + '">' + (r.status || '—') + '</td>' +
            '<td>' + (r.stage || '—') + '</td>' +
            '<td>' + formatDate(r.finished_at) + '</td>' +
            '<td class="error-cell" title="' + (r.error_message || '').replace(/"/g, '&quot;') + '">' + (r.error_message ? r.error_message.slice(0, 40) + (r.error_message.length > 40 ? '…' : '') : '—') + '</td>' +
            '<td><button type="button" class="view-detail" data-run-id="' + r.run_id + '">View</button></td>' +
            '</tr>'
          );
        }).join('');

    // Attach view-detail handlers
    document.querySelectorAll('.view-detail').forEach(function (btn) {
      btn.addEventListener('click', function () {
        const runId = btn.getAttribute('data-run-id');
        if (runId) fetchRunDetail(runId);
      });
    });
  }

  function fetchRuns() {
    fetch('/runs')
      .then(function (res) { return res.json(); })
      .then(function (data) { renderRuns(data.runs || []); })
      .catch(function (err) {
        console.error('Failed to fetch runs', err);
        if (RUNS_TBODY) RUNS_TBODY.innerHTML = '<tr><td colspan="9">Failed to load runs.</td></tr>';
      });
  }

  function fetchRunDetail(runId) {
    fetch('/runs/' + encodeURIComponent(runId))
      .then(function (res) {
        if (!res.ok) throw new Error('Not found');
        return res.json();
      })
      .then(function (run) {
        DETAIL_BODY.textContent = JSON.stringify(run, null, 2);
        DETAIL_SECTION.hidden = false;
      })
      .catch(function (err) {
        DETAIL_BODY.textContent = 'Error: ' + err.message;
        DETAIL_SECTION.hidden = false;
      });
  }

  function hasRunningRun(runs) {
    return (runs || []).some(function (r) { return r.status === 'running'; });
  }

  function startRefreshWhenRunning() {
    if (refreshTimer) return;
    function tick() {
      fetch('/runs')
        .then(function (res) { return res.json(); })
        .then(function (data) {
          renderRuns(data.runs || []);
          if (!hasRunningRun(data.runs)) {
            clearInterval(refreshTimer);
            refreshTimer = null;
          }
        })
        .catch(function () {});
    }
    refreshTimer = setInterval(tick, REFRESH_INTERVAL_MS);
    tick();
  }

  RUN_NOW_BTN.addEventListener('click', function () {
    var originEl = document.getElementById('origin');
    var destEl = document.getElementById('destination');
    var origin = originEl ? originEl.value : 'dev';
    var destination = destEl ? destEl.value : 'dev';
    RUN_NOW_BTN.disabled = true;
    setFeedback('Starting…');
    fetch('/runs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ origin: origin, destination: destination }),
    })
      .then(function (res) { return res.json(); })
      .then(function (data) {
        setFeedback('Run started: ' + shortId(data.run_id) + ' (' + (data.origin || 'dev') + ' → ' + (data.destination || 'dev') + '). Check the table for status.');
        fetchRuns();
        startRefreshWhenRunning();
      })
      .catch(function (err) {
        setFeedback('Failed to start run: ' + err.message, true);
      })
      .finally(function () {
        RUN_NOW_BTN.disabled = false;
      });
  });

  DETAIL_CLOSE.addEventListener('click', function () {
    DETAIL_SECTION.hidden = true;
  });

  fetchRuns();
})();
