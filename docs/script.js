/* ============================================================
   NexLink Landing Page — script.js
   Pure vanilla JS. No framework. No dependencies.
   Fails gracefully if GitHub API is unavailable.
   ============================================================ */

'use strict';

/* ---- Config ---- */
const GITHUB_OWNER = 'highnine699-del';
const GITHUB_REPO = 'nexlink-updates';
const FALLBACK_VER = 'v1.3.13';
const API_BASE = 'https://api.github.com/repos/' + GITHUB_OWNER + '/' + GITHUB_REPO;

/* ============================================================
   1. LIVE DATA — fetch version, release notes, stats
   ============================================================ */

/**
 * Fetch the latest release from GitHub and use it to:
 *   - Fill version numbers throughout the page
 *   - Render the release notes box
 */
async function fetchLatestRelease() {
  try {
    const res = await fetch(API_BASE + '/releases/latest', {
      headers: { 'Accept': 'application/vnd.github.v3+json' }
    });
    if (!res.ok) throw new Error('GitHub API responded with ' + res.status);
    const data = await res.json();

    const version = data.tag_name || FALLBACK_VER;

    /* Update every version display */
    setTextById('heroVersion', version);
    setTextById('ctaVersion', version);
    setTextById('footerVersion', version);

    /* Render release notes box */
    renderReleaseBox(data);

  } catch (err) {
    /* Graceful fallback — page still works, version stays at fallback */
    console.warn('[NexLink] Could not fetch latest release:', err.message);
  }
}

/**
 * Fetch total release count and use it in the stats row.
 * Commit count is hardcoded at build time because the Commits
 * API requires authentication for accurate totals on some repos.
 */
async function fetchReleaseCount() {
  try {
    /* GitHub paginates at 30 per page — grab page 1 and check Link header,
       or just pull all with per_page=100 (NexLink has far fewer than 100). */
    const res = await fetch(API_BASE + '/releases?per_page=100', {
      headers: { 'Accept': 'application/vnd.github.v3+json' }
    });
    if (!res.ok) throw new Error('releases list: ' + res.status);
    const releases = await res.json();
    if (Array.isArray(releases)) {
      setTextById('statReleases', releases.length);
    }
  } catch (err) {
    console.warn('[NexLink] Could not fetch release count:', err.message);
    /* Leave the '—' fallback in place */
  }
}

function renderReleaseBox(release) {
  const box = document.getElementById('releaseBox');
  if (!box) return;

  /* Sanitise the release body before inserting */
  const body = release.body ? sanitise(release.body).substring(0, 800) : 'No notes for this release.';
  const tagName = release.tag_name || FALLBACK_VER;
  const name = release.name ? sanitise(release.name) : tagName;
  const date = release.published_at
    ? new Date(release.published_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
    : '';

  box.innerHTML =
    '<p class="release-tag">' + tagName + '</p>' +
    '<p class="release-name">' + name + '</p>' +
    '<pre class="release-body">' + body + '</pre>' +
    (date ? '<p class="release-date">Released ' + date + '</p>' : '');
}

/* Plain-text sanitiser — strips HTML tags so injected markup can't execute */
function sanitise(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function setTextById(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

/* ============================================================
   2. SCROLL-REVEAL via IntersectionObserver
   ============================================================ */
function initScrollReveal() {
  /* Bail out if reduced-motion is preferred — CSS handles it */
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  /* Bail out gracefully if IntersectionObserver isn't available */
  if (!('IntersectionObserver' in window)) {
    document.querySelectorAll('.reveal').forEach(function (el) {
      el.classList.add('visible');
    });
    return;
  }

  const observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        const el = entry.target;
        const delay = el.dataset.delay || 0;
        setTimeout(function () {
          el.classList.add('visible');
        }, Number(delay));
        observer.unobserve(el);
      }
    });
  }, {
    threshold: 0.15,
    rootMargin: '0px 0px -40px 0px'
  });

  /* Stagger steps by 100ms each */
  document.querySelectorAll('.reveal').forEach(function (el, index) {
    el.dataset.delay = index * 100;
    observer.observe(el);
  });
}

/* ============================================================
   3. FAQ ACCORDION
   ============================================================ */
function initFaq() {
  document.querySelectorAll('.faq-question').forEach(function (btn) {
    btn.addEventListener('click', function () {
      const answer = btn.nextElementSibling;
      const expanded = btn.getAttribute('aria-expanded') === 'true';

      /* Close all others */
      document.querySelectorAll('.faq-question').forEach(function (other) {
        if (other !== btn) {
          other.setAttribute('aria-expanded', 'false');
          const otherAnswer = other.nextElementSibling;
          if (otherAnswer) {
            otherAnswer.classList.remove('open');
            otherAnswer.hidden = true;
          }
        }
      });

      /* Toggle this one */
      if (expanded) {
        btn.setAttribute('aria-expanded', 'false');
        answer.classList.remove('open');
        answer.hidden = true;
      } else {
        btn.setAttribute('aria-expanded', 'true');
        answer.hidden = false;
        /* next frame so height transition works after hidden is removed */
        requestAnimationFrame(function () {
          answer.classList.add('open');
        });
      }
    });
  });
}

/* ============================================================
   4. SECURITY FLOW ANIMATION
   Adds .flow-visible to #security when it enters the viewport.
   CSS transition-delay per [data-flow-index] does the rest.
   Bails gracefully if reduced-motion or no IntersectionObserver.
   ============================================================ */
function initSecurityFlowAnimation() {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    /* CSS already sets opacity:1/transform:none for reduced-motion — nothing to do */
    return;
  }

  const section = document.getElementById('security');
  if (!section) return;

  if (!('IntersectionObserver' in window)) {
    /* Fallback: reveal immediately */
    section.classList.add('flow-visible');
    return;
  }

  const observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add('flow-visible');
        observer.unobserve(entry.target);
      }
    });
  }, {
    threshold: 0.2
  });

  observer.observe(section);
}

/* ============================================================
   5. INIT
   ============================================================ */
document.addEventListener('DOMContentLoaded', function () {
  initScrollReveal();
  initFaq();
  initSecurityFlowAnimation();

  /* Fire API calls in parallel — page works fine if both fail */
  fetchLatestRelease();
  fetchReleaseCount();
});
