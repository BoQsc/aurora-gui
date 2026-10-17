// An external classic script, loaded the way a real page loads its behaviour
// (the Django site's header pulls its theme switcher in exactly this way).
//
// The engine must fetch it, run it before the inline script that follows it,
// and keep the state it creates on the window and in the browser APIs.
window.markRan = true;
document.documentElement.setAttribute('data-mark', 'ran');
document.getElementById('heading').textContent = 'heading rewritten by mark.js';
document.getElementById('r1').textContent = 'external script ran';

// window.matchMedia: answered from the layout viewport.
var mq = window.matchMedia('(min-width: 100px) and (max-width: 4000px)');
document.getElementById('r2').textContent =
    'matchMedia ' + (mq.matches ? 'matched' : 'did not match');

// document.cookie: the document's cookie jar.
document.cookie = 'theme=dark; max-age=3600; path=/';
document.getElementById('r3').textContent = 'cookie ' + document.cookie;

// localStorage: the Web Storage API.
localStorage.setItem('theme', 'dark');
document.getElementById('r4').textContent = 'storage ' + localStorage.getItem('theme');
