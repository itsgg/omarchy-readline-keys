import QtQuick
import Quickshell

// Adds readline keys (Ctrl+N/P/F/B to navigate, Ctrl+M for Enter, Ctrl+[ for
// Escape) to Omarchy's keyboard-driven popups WITHOUT modifying or forking any
// of them.
//
// Omarchy hardcodes popup navigation in if/else chains over `event.key`, and
// none of these surfaces uses a real text input, so Qt's standard editing keys
// never apply. The usual workaround - `omarchy plugin clone` - forks 1000+ lines
// of upstream QML that then never receives another upstream fix.
//
// This takes the other route. As a `service` plugin it is handed the live
// `shell` object, walks to each popup's key-handling Item at runtime, parents a
// tiny focused Item under it, and calls the popup's own public functions
// (select / goBack / activateIndex / selectAdjacent / cancel). Keys we do not
// claim propagate to the original handler untouched, so every stock binding
// still works and the popups stay 100% upstream code.

Item {
  id: root

  // Injected by omarchy-shell (see shell.qml, ensureService).
  property var shell: null
  property var pluginRegistry: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var manifest: null

  property bool debug: false
  function log(m) { if (debug) console.warn("readline-keys: " + m) }

  // The menu binds Enter, Right and (through us) Ctrl+F to one branch, dmenu
  // variants included, so `fwd` and `accept` share this. activateIndex() is
  // bounds-checked upstream and resolves dmenu's "input" mode itself, which is
  // why the row count and the mode never have to be read from out here.
  //
  // The first press only arms the cursor, which upstream does as
  // `if (displayModel.count > 0) cursorActive = true`. displayModel is private
  // to the popup, so arm it through select(0) instead: it carries the same
  // empty-list guard, and it lands on row 0, which is where selectedIndex
  // already sits every time upstream clears cursorActive.
  function menuActivate(h) {
    if (h.dmenuActive) h.activateIndex(h.cursorActive ? h.selectedIndex : 0)
    else if (h.cursorActive) h.activateIndex(h.selectedIndex)
    else h.select(0)
  }

  // Per-surface semantics. Emacs reading: N/P move by line, F/B move within it.
  //   menu         a vertical list inside a hierarchy - F descends, B goes back
  //   clipboard    a single column - no horizontal axis, so F/B are unbound
  //   emojis       a grid - the case the emacs mapping fits exactly
  //   image-picker one horizontal strip - every key steps the strip
  // `accept` and `abort` are the terminal control codes for Enter and Escape
  // (Ctrl+M is CR, Ctrl+[ is ESC), so each one mirrors what that surface
  // already does with the real key, filter-clearing step and all.
  readonly property var surfaces: ({
    "omarchy.menu": {
      // The uninstall confirmation takes over the popup's key handling; acting
      // underneath it would move a selection the user can no longer see.
      blocked: function(h) { return h.deleteConfirmOpen === true },
      next:   function(h) { h.select(1) },
      prev:   function(h) { h.select(-1) },
      fwd:    function(h) { root.menuActivate(h) },
      back:   function(h) { h.goBack() },
      accept: function(h) { root.menuActivate(h) },
      abort:  function(h) { if (h.filterText) h.setFilter(""); else h.cancel() }
    },
    "omarchy.clipboard": {
      blocked: function(h) { return h.clearConfirmOpen === true },
      next:   function(h) { h.select(1) },
      prev:   function(h) { h.select(-1) },
      accept: function(h) { if (h.cursorActive) h.activateIndex(h.selectedIndex)
                            else h.select(0) },
      abort:  function(h) { if (h.filterText) h.setFilter(""); else h.close() }
    },
    "omarchy.emojis": {
      next:   function(h) { h.selectRow(1) },
      prev:   function(h) { h.selectRow(-1) },
      fwd:    function(h) { h.select(1) },
      back:   function(h) { h.select(-1) },
      accept: function(h) { if (h.cursorActive) h.activateIndex(h.selectedIndex)
                            else h.select(0) },
      abort:  function(h) { if (h.filterText) h.setFilter(""); else h.dismiss() }
    },
    "omarchy.image-picker": {
      next:   function(h) { h.selectAdjacent(1) },
      prev:   function(h) { h.selectAdjacent(-1) },
      fwd:    function(h) { h.selectAdjacent(1) },
      back:   function(h) { h.selectAdjacent(-1) },
      accept: function(h) { h.applySelected() },
      abort:  function(h) { if (h.filterText) h.updateFilter(""); else h.cancel() }
    }
  })

  property var probes: ({})
  property var openState: ({})

  // A user may be running a clone of a built-in (omarchy plugin clone), which
  // carries a different id but declares what it replaced.
  function surfaceKeyFor(pluginId) {
    if (surfaces[pluginId] !== undefined) return pluginId
    var m = pluginRegistry && pluginRegistry.installedPlugins
      ? pluginRegistry.installedPlugins[pluginId] : null
    var from = m && m.omarchy ? String(m.omarchy.clonedFrom || "") : ""
    return surfaces[from] !== undefined ? from : ""
  }

  // Each popup renders into its own layer-shell window, so key events never
  // reach the plugin root - hence descending through `contentItem` below.
  function isProbe(o) {
    try { return String(o.objectName) === "readlineKeys" } catch (e) { return false }
  }

  function poolsOf(o) {
    var pools = []
    try { if (o.contentItem) pools.push([o.contentItem]) } catch (e) {}
    try { if (o.data) pools.push(o.data) } catch (e) {}
    try { if (o.children) pools.push(o.children) } catch (e) {}
    return pools
  }

  // A probe is parented to the popup, not to this service, so one outlives us
  // when this plugin alone is disabled while the popups stay loaded. (A full
  // plugin reload unloads panels before services, so those die with the panel.)
  // Clear any we find before
  // attaching, otherwise the search below would nest a new probe under the old
  // one (an orphan still reports focus === true) and both would fire.
  function reclaimOrphans(o, depth) {
    if (!o || depth > 12) return
    var pools = poolsOf(o)
    for (var p = 0; p < pools.length; p++)
      for (var i = 0; i < pools[p].length; i++) {
        var c = pools[p][i]
        if (isProbe(c)) { try { c.destroy() } catch (e) {}; continue }
        reclaimOrphans(c, depth + 1)
      }
  }

  // Find the popup's key handler. `focus: true` alone is too weak - it also
  // matches nested focus scopes and focused controls inside dialogs - so we
  // take the DEEPEST visible focused item and prefer one that actually holds
  // activeFocus, which is by definition where key events are being delivered.
  function findHandler(o, depth, best) {
    if (!o || depth > 12) return best
    var focused = false, active = false, shown = true
    try { focused = (o.focus === true && o.children !== undefined) } catch (e) {}
    try { active = (o.activeFocus === true) } catch (e) {}
    try { if (o.visible === false) shown = false } catch (e) {}
    if (focused && shown && depth > 0 && !isProbe(o)) {
      var cand = { item: o, depth: depth, active: active }
      if (!best) best = cand
      else if (active !== best.active) { if (active) best = cand }   // activeFocus wins outright
      else if (depth > best.depth) best = cand                       // otherwise the deeper one
    }
    var pools = poolsOf(o)
    for (var p = 0; p < pools.length; p++)
      for (var i = 0; i < pools[p].length; i++)
        best = findHandler(pools[p][i], depth + 1, best)
    return best
  }

  // `claim` is set per surface, so a chord with no action bound (Ctrl+F in the
  // clipboard, which is a single column) is never accepted and propagates to
  // the popup's own handler exactly as if this plugin were not installed.
  readonly property string probeQml:
    'import QtQuick; Item { objectName: "readlineKeys"; focus: true; \
     property var claim: ({}); property var blockedFn: null; \
     property bool handled: false; \
     signal act(string what); \
     Keys.onPressed: function(e) { \
       if (e.modifiers !== Qt.ControlModifier) return; \
       var what = e.key === Qt.Key_N ? "next"   : e.key === Qt.Key_P ? "prev" \
                : e.key === Qt.Key_F ? "fwd"    : e.key === Qt.Key_B ? "back" \
                : e.key === Qt.Key_M ? "accept" : e.key === Qt.Key_BracketLeft ? "abort" \
                : ""; \
       if (!what || claim[what] !== true) return; \
       if (blockedFn && blockedFn()) return; \
       handled = false; act(what); e.accepted = handled; \
     } }'

  // Only ever take focus for a popup that is genuinely open. Attaching to all of
  // them and focusing unconditionally makes our own probes fight each other for
  // focus, and whichever grabbed it last swallows the keys. This mirrors the
  // shell's own isPluginOpen(): trust the root's `opened`, fall back to summon
  // state, which is set before the loader resolves and so cannot be trusted alone.
  function isOpen(pluginId, host) {
    // Only a real boolean counts. A clone exposing `opened` as null, a number,
    // or an uninitialised value would otherwise suppress the fallback and leave
    // that popup permanently unfocused.
    try { if (host && typeof host.opened === "boolean") return host.opened } catch (e) {}
    return !!(shell && shell.openPanelIds && shell.openPanelIds[pluginId] === true)
  }

  function rememberOpen(pluginId, open) {
    var n = ({}); for (var k in openState) n[k] = openState[k]; n[pluginId] = open; openState = n
  }

  function dropProbe(pluginId) {
    try { if (probes[pluginId]) probes[pluginId].destroy() } catch (e) {}
    var n = ({}); for (var k in probes) if (k !== pluginId) n[k] = probes[k]; probes = n
  }

  function attach(pluginId) {
    var key = surfaceKeyFor(pluginId)
    if (!key) return
    var loader = shell && shell.panelLoaders ? shell.panelLoaders[pluginId] : null
    if (!loader || !loader.item) return

    var open = isOpen(pluginId, loader.item)
    var wasOpen = openState[pluginId] === true
    if (open !== wasOpen) rememberOpen(pluginId, open)

    var existing = probes[pluginId]
    // A destroyed QObject leaves an invalidated wrapper in the map; touching it
    // throws, so probe it defensively rather than trusting the entry.
    var alive = false
    try { alive = !!(existing && existing.parent) } catch (e) { alive = false }

    if (alive && !(open && !wasOpen)) {
      if (!open || existing.activeFocus) return
      // Reclaim focus ONLY from the handler we attached under. That is the
      // popup re-priming its own focus target, which it does on every summon
      // and navigation. If anything else inside the popup holds focus (a
      // confirmation dialog, an inline editor) it wants the keys, and taking
      // them back would leave it dead.
      var parentFocused = false
      try { parentFocused = !!(existing.parent && existing.parent.activeFocus === true) } catch (e) {}
      if (parentFocused) existing.forceActiveFocus()
      return
    }

    // Either there is no probe, or the popup just went from closed to open.
    // Re-attach on that transition: the previous probe may have been created
    // while the popup was closed or still building, and the handler can move.
    if (alive) dropProbe(pluginId)

    reclaimOrphans(loader.item, 0)
    var found = findHandler(loader.item, 0, null)
    if (!found) return
    var handler = found.item

    var probe = Qt.createQmlObject(probeQml, handler, "readlineKeys")
    if (!probe) { console.warn("readline-keys: could not create probe for " + pluginId); return }

    var host = loader.item
    var actions = surfaces[key]
    probe.claim = ({
      next:   actions.next   !== undefined, prev:  actions.prev  !== undefined,
      fwd:    actions.fwd    !== undefined, back:  actions.back  !== undefined,
      accept: actions.accept !== undefined, abort: actions.abort !== undefined
    })
    if (actions.blocked) probe.blockedFn = function() {
      try { return actions.blocked(host) === true } catch (e) { return false }
    }
    // Signal delivery is synchronous, so `handled` is set before Keys.onPressed
    // reads it back to decide whether to accept the event.
    probe.act.connect(function(what) {
      var fn = actions[what]
      if (!fn) return
      try { fn(host); probe.handled = true }
      catch (e) { console.warn("readline-keys: " + pluginId + " " + what + ": " + e) }
    })
    if (open) probe.forceActiveFocus()

    var n = ({}); for (var k in probes) n[k] = probes[k]; n[pluginId] = probe; probes = n
    log("attached to " + pluginId + " (" + key + ")")
  }

  function attachAll() {
    if (!shell || !shell.panelLoaders) return
    for (var id in shell.panelLoaders) attach(id)
  }

  function anyOpen() {
    if (!shell || !shell.panelLoaders) return false
    for (var id in shell.panelLoaders) {
      if (!surfaceKeyFor(id)) continue
      var l = shell.panelLoaders[id]
      if (l && l.item && isOpen(id, l.item)) return true
    }
    return false
  }

  Connections {
    target: root.shell || null
    ignoreUnknownSignals: true
    function onPanelLoadersChanged() { root.attachAll() }
    function onOpenPanelIdsChanged() { root.attachAll() }
  }

  // Deliberately unconditional. Gating `running` on a function that reads
  // `shell` captured no binding dependency (shell is still null when the
  // binding first evaluates, so the function returns before touching it) and
  // the timer then never ticked at all. Each tick is a handful of map lookups
  // and one activeFocus check, and focus is only taken for the popup that is
  // actually open, so this is cheap and cannot start a focus fight.
  Timer {
    interval: 150
    repeat: true
    running: !!root.shell
    onTriggered: root.attachAll()
  }

  // Probes are children of the popups, which are keepLoaded and so outlive us.
  // Without this, disabling the plugin leaves a live probe still claiming keys.
  function detachAll() {
    for (var id in probes) { try { if (probes[id]) probes[id].destroy() } catch (e) {} }
    probes = ({})
  }

  Component.onCompleted: attachAll()
  Component.onDestruction: detachAll()
}
