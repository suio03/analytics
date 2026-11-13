(function(){
  'use strict';

  var location = window.location
  var document = window.document

  {{#if compat}}
  var scriptEl = document.getElementById('plausible');
  {{else}}
  var scriptEl = document.currentScript;
  {{/if}}
  var endpoint = scriptEl.getAttribute('data-api') || defaultEndpoint(scriptEl)
  var dataDomain = scriptEl.getAttribute('data-domain')

  // Set once the visitor clicks, taps, types or scrolls with a wheel. Sent as
  // `i` so the server can tell sessions with real interaction apart.
  var interacted = false
  var interactionEvents = ['pointerdown', 'keydown', 'touchstart', 'wheel']
  function onInteraction() {
    interacted = true
    for (var j = 0; j < interactionEvents.length; j++) {
      window.removeEventListener(interactionEvents[j], onInteraction, true)
    }
  }
  for (var k = 0; k < interactionEvents.length; k++) {
    window.addEventListener(interactionEvents[k], onInteraction, {capture: true, passive: true})
  }

  // Automation signals, sent as the `a` bitmask on pageviews and classified
  // on the server (Plausible.Ingestion.Traffic) instead of dropping the event.
  function automationSignals() {
    if (window.__plausible) return 0
    var nav = window.navigator
    var bits = 0
    if (nav.webdriver) bits |= 1
    if (window._phantom || window.callPhantom || window.__nightmare || window.domAutomation || window.domAutomationController) bits |= 2
    if (window.outerWidth === 0 && window.outerHeight === 0) bits |= 4
    if (nav.languages && nav.languages.length === 0) bits |= 8
    return bits
  }

  // Cookie mode: a random visitor id kept in a first-party cookie on the site's root domain
  // (shared by its subdomains) and mirrored in localStorage, sent as `v`. The server derives
  // the visitor from it instead of IP + user agent, so returning visitors are recognised across
  // days. `data-cookieless` on the script tag turns it off and stores nothing.
  var visitorId = scriptEl.hasAttribute('data-cookieless') ? null : loadVisitorId()

  function loadVisitorId() {
    var name = 'rc_vid'
    var id = null
    try {
      var match = document.cookie.match(/(?:^|; )rc_vid=([A-Za-z0-9_-]{8,64})(?:;|$)/)
      id = match ? match[1] : window.localStorage.getItem(name)
    } catch (e) {}
    if (!id || !/^[A-Za-z0-9_-]{8,64}$/.test(id)) id = randomId()

    try {
      var attrs = '; path=/; max-age=34560000; samesite=lax' + (location.protocol === 'https:' ? '; secure' : '')
      var parts = location.hostname.split('.')
      var stored = false
      // Try the widest domain first; browsers refuse public suffixes such as "co.uk".
      for (var n = 2; n <= parts.length && !stored && parts.length > 1; n++) {
        var domain = parts.slice(-n).join('.')
        document.cookie = name + '=' + id + attrs + '; domain=' + domain
        stored = document.cookie.indexOf(name + '=' + id) !== -1
      }
      if (!stored) document.cookie = name + '=' + id + attrs
    } catch (e) {}
    try { window.localStorage.setItem(name, id) } catch (e) {}
    return id
  }

  function randomId() {
    var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    var out = ''
    var bytes = null
    try {
      bytes = new Uint8Array(20)
      window.crypto.getRandomValues(bytes)
    } catch (e) { bytes = null }
    for (var j = 0; j < 20; j++) {
      out += chars.charAt((bytes ? bytes[j] : Math.floor(Math.random() * 256)) % 62)
    }
    return out
  }

  function onIgnoredEvent(reason, options) {
    if (reason) console.warn('Ignoring Event: ' + reason);
    options && options.callback && options.callback()
  }

  function defaultEndpoint(el) {
    {{#if compat}}
    var pathArray = el.src.split( '/' );
    var protocol = pathArray[0];
    var host = pathArray[2];
    return protocol + '//' + host  + '/api/event';
    {{else}}
    return new URL(el.src).origin + '/api/event'
    {{/if}}
  }

  {{#if pageleave}}
  // :NOTE: Tracking pageleave events is currently experimental.

  // Multiple pageviews might be sent by the same script when the page
  // uses client-side routing (e.g. hash or history-based). This flag
  // prevents registering multiple listeners in those cases.
  var listeningPageLeave = false

  // In SPA-s, multiple listeners that trigger the pageleave event
  // might fire nearly at the same time. E.g. when navigating back
  // in browser history while using hash-based routing - a popstate
  // and hashchange will be fired in a very quick succession. This
  // flag prevents sending multiple pageleaves in those cases.
  var pageLeaveSending = false

  function triggerPageLeave(url) {
    if (pageLeaveSending) {return}
    pageLeaveSending = true
    setTimeout(function () {pageLeaveSending = false}, 500)

    var payload = {
      n: 'pageleave',
      d: dataDomain,
      u: url,
    }
    if (interacted) payload.i = 1
    if (visitorId) payload.v = visitorId

    {{#if hash}}
    payload.h = 1
    {{/if}}

    if (navigator.sendBeacon) {
      var blob = new Blob([JSON.stringify(payload)], { type: 'text/plain' });
      navigator.sendBeacon(endpoint, blob)
    }
  }

  function registerPageLeaveListener(url) {
    if (listeningPageLeave) { return }

    window.addEventListener('pagehide', function () {
      triggerPageLeave(url)
    })

    listeningPageLeave = true
  }
  {{/if}}


  function trigger(eventName, options) {
    {{#unless local}}
    if (/^localhost$|^127(\.[0-9]+){0,2}\.[0-9]+$|^\[::1?\]$/.test(location.hostname) || location.protocol === 'file:') {
      return onIgnoredEvent('localhost', options)
    }
    if (window.Cypress && !window.__plausible) {
      return onIgnoredEvent(null, options)
    }
    {{/unless}}
    try {
      if (window.localStorage.plausible_ignore === 'true') {
        return onIgnoredEvent('localStorage flag', options)
      }
    } catch (e) {

    }
    {{#if exclusions}}
    var dataIncludeAttr = scriptEl && scriptEl.getAttribute('data-include')
    var dataExcludeAttr = scriptEl && scriptEl.getAttribute('data-exclude')

    if (eventName === 'pageview') {
      var isIncluded = !dataIncludeAttr || (dataIncludeAttr && dataIncludeAttr.split(',').some(pathMatches))
      var isExcluded = dataExcludeAttr && dataExcludeAttr.split(',').some(pathMatches)

      if (!isIncluded || isExcluded) return onIgnoredEvent('exclusion rule', options)
    }

    function pathMatches(wildcardPath) {
      var actualPath = location.pathname

      {{#if hash}}
      actualPath += location.hash
      {{/if}}

      return actualPath.match(new RegExp('^' + wildcardPath.trim().replace(/\*\*/g, '.*').replace(/([^\.])\*/g, '$1[^\\s\/]*') + '\/?$'))
    }
    {{/if}}

    var payload = {}
    payload.n = eventName
    {{#if manual}}
    payload.u = options && options.u ? options.u : location.href
    {{else}}
    payload.u = location.href
    {{/if}}
    payload.d = dataDomain
    payload.r = document.referrer || null
    if (options && options.meta) {
      payload.m = JSON.stringify(options.meta)
    }
    if (options && options.props) {
      payload.p = options.props
    }
    {{#if revenue}}
    if (options && options.revenue) {
      payload.$ = options.revenue
    }
    {{/if}}

    {{#if pageview_props}}
    var propAttributes = scriptEl.getAttributeNames().filter(function (name) {
      return name.substring(0, 6) === 'event-'
    })

    var props = payload.p || {}

    propAttributes.forEach(function(attribute) {
      var propKey = attribute.replace('event-', '')
      var propValue = scriptEl.getAttribute(attribute)
      props[propKey] = props[propKey] || propValue
    })

    payload.p = props
    {{/if}}

    {{#if hash}}
    payload.h = 1
    {{/if}}

    if (eventName === 'pageview') {
      var automation = automationSignals()
      if (automation) payload.a = automation
    }
    if (interacted) payload.i = 1
    if (visitorId) payload.v = visitorId

    var request = new XMLHttpRequest();
    request.open('POST', endpoint, true);
    request.setRequestHeader('Content-Type', 'text/plain');

    request.send(JSON.stringify(payload));

    request.onreadystatechange = function() {
      if (request.readyState === 4) {
        {{#if pageleave}}
        if (eventName === 'pageview') {
          registerPageLeaveListener(payload.u)
        }
        {{/if}}
        options && options.callback && options.callback({status: request.status})
      }
    }
  }

  var queue = (window.plausible && window.plausible.q) || []
  window.plausible = trigger
  // Lets the site pass the visitor to its checkout (e.g. Paddle custom_data) and server events.
  trigger.visitorId = visitorId
  for (var i = 0; i < queue.length; i++) {
    trigger.apply(this, queue[i])
  }

  {{#unless manual}}
    var lastPage;

    {{#if pageleave}}
    var lastUrl = location.href

    function pageLeaveSPA() {
      triggerPageLeave(lastUrl);
      lastUrl = location.href;
    }
    {{/if}}

    function page(isSPANavigation) {
      {{#unless hash}}
      if (lastPage === location.pathname) return;
      {{/unless}}
      
      {{#if pageleave}}
      if (isSPANavigation) {pageLeaveSPA()}
      {{/if}}

      lastPage = location.pathname
      trigger('pageview')
    }

    var onSPANavigation = function() {page(true)}

    {{#if hash}}
    window.addEventListener('hashchange', onSPANavigation)
    {{else}}
    var his = window.history
    if (his.pushState) {
      var originalPushState = his['pushState']
      his.pushState = function() {
        originalPushState.apply(this, arguments)
        onSPANavigation();
      }
      window.addEventListener('popstate', onSPANavigation)
    }
    {{/if}}

    function handleVisibilityChange() {
      if (!lastPage && document.visibilityState === 'visible') {
        page()
      }
    }

    if (document.visibilityState === 'prerender') {
      document.addEventListener('visibilitychange', handleVisibilityChange);
    } else {
      page()
    }

    {{#if pageleave}}
    window.addEventListener('pageshow', function(event) {
      if (event.persisted) {
        // Page was restored from bfcache - trigger a pageview
        page();
      }
    })
    {{/if}}
  {{/unless}}

  {{#if (any outbound_links file_downloads tagged_events)}}
  {{> customEvents}}
  {{/if}}
})();
