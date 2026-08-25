// PickleRecord site behaviour.
// 1. Sticky watch: swap the screenshot as each beat crosses the viewport centre.
(function () {
  var img = document.getElementById('stickyWatch');
  var beats = [].slice.call(document.querySelectorAll('.beat[data-screen]'));
  if (!img || !beats.length) return;

  var SHOTS = {
    start: '/assets/shots/watch-start.webp',
    score: '/assets/shots/watch-score.webp',
    entry: '/assets/shots/watch-entry.webp',
    games: '/assets/shots/watch-games.webp'
  };
  var ALT = {
    start: 'PickleRecord on Apple Watch: a Level picker set to All Levels, a Track swings toggle switched on, and a green outlined Start Session button with a plus icon',
    score: 'PickleRecord on Apple Watch: an active Open Play session showing a 3–1 score, All Levels subtext, a green Win button, a red Loss button, and a Game 1 · Win row beneath',
    entry: 'PickleRecord on Apple Watch: the Score entry sheet with You 11 and Them 4 rows, red minus and green plus steppers, and an "or say \'11 7\'" voice-entry hint',
    games: 'PickleRecord on Apple Watch: the Open Play game list showing Game 1 Win 11–0, Game 2 Win 11–4, Game 3 Win 11–0, and Game 4 Loss 10–12'
  };

  // Preload so the swap never flashes an empty frame.
  Object.keys(SHOTS).forEach(function (k) { new Image().src = SHOTS[k]; });

  var current = '';
  function show(key) {
    if (key === current || !SHOTS[key]) return;
    current = key;
    img.src = SHOTS[key];
    img.alt = ALT[key];
  }

  beats[0].classList.add('on');
  if (!('IntersectionObserver' in window)) return; // static first screen is fine
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (!e.isIntersecting) return;
      beats.forEach(function (b) { b.classList.remove('on'); });
      e.target.classList.add('on');
      show(e.target.getAttribute('data-screen'));
    });
  }, { rootMargin: '-40% 0px -50% 0px' });
  beats.forEach(function (b) { io.observe(b); });
})();
