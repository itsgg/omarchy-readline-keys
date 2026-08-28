# Extending a built-in Omarchy plugin without forking it

This repo is a worked example of a general technique. If you want to change how
one of Omarchy's built-in shell plugins behaves and there is no config for it,
you do not have to fork the plugin.

Everything below was verified against Omarchy 4.0.1-1. Nothing here is a
documented, supported API. It is the shell's own internal wiring, which is why
the pitfalls at the end matter.

## The problem with the obvious route

`omarchy plugin clone <id>` copies a built-in into
`~/.config/omarchy/plugins/<user>.<id>/` and switches the shell to your copy. It
works immediately, and then it rots:

- the clone is a plain `cp -aL`, with no git and no remote
- `omarchy plugin update` requires `<dir>/.git` and does `fetch origin HEAD` +
  `merge --ff-only`, so it skips clones entirely
- `omarchy update` does not itself update local plugins, and no shipped
  migration writes to `~/.config/omarchy/plugins/`, though it does run all
  migrations and a post-update hook, so this is a property of what currently
  ships, not a guarantee of the update mechanism

So your fork keeps running the code it was copied from while upstream moves on.
Fork 1900 lines of `Menu.qml` for six keybindings and you silently stop
receiving every fix to the other 1894.

## The technique

Ship a `kind: "service"` plugin. Services are instantiated at shell startup and
handed the live shell by property injection. `shell.qml`'s `ensureService()`
sets any of `omarchyPath`, `shell`, `manifest`, `barWidgetRegistry` and
`pluginRegistry` that your root object declares:

```qml
Item {
  property var shell: null
  property var pluginRegistry: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
}
```

From `shell` you can reach every loaded popup:

| What | Where |
|---|---|
| Loaded panels/overlays/menus | `shell.panelLoaders`, plugin id to `Loader` |
| The plugin's root object | `shell.panelLoaders[id].item` |
| Which have been summoned | `shell.openPanelIds`, id to `true` |
| Manifests, incl. clone metadata | `pluginRegistry.installedPlugins[id]` |

`panelLoaders` holds only enabled plugins of kind `panel`, `overlay` or `menu`.
Services, the bar, and pure bar widgets are routed elsewhere and are not in it.
`openPanelIds` is summon state, not visibility: the id is inserted before the
loader resolves and before the plugin's `open()` is called. If you need the actual
open state, check the root's own `opened` property, which is what the shell
does.

Both are `property var`, so `onPanelLoadersChanged` / `onOpenPanelIdsChanged`
fire and you can react rather than poll.

The four built-ins this repo targets each have a plain `Item` root whose public
functions are its real API: `select()`, `goBack()`, `activateIndex()`,
`selectAdjacent()`. Call those and you inherit the popup's own behavior instead
of reimplementing it.

Be aware that this is a property of those plugins, not a contract. The loader
requires no particular root type and calls only optional `open()` / `close()`.
Check the plugin you are targeting rather than assuming.

### Reaching the UI

The root `Item` is not where the UI lives. Each of these popups renders into its
own layer-shell `PanelWindow`, so key and mouse events inside the popup never
reach that root. To get inside, descend through `contentItem` as well as `data`
and `children` while walking. Again, one window per plugin is what these four
happen to do, not something the shell enforces.

### Adding key handling

You cannot set an attached property (`Keys.onPressed`) on an object you did not
declare. What you *can* do is create a focused child of the item that already
handles keys:

1. find that item: the deepest visible one declaring `focus: true`, preferring
   one holding `activeFocus`, since that is by definition where key events are
   being delivered
2. `Qt.createQmlObject(..., thatItem)` with `focus: true` and your own
   `Keys.onPressed`
3. `forceActiveFocus()`

Key events go to the focused item first, so you get first refusal. **Anything
you do not `accept` propagates up to the original handler**, so every stock
binding, including the letters driving the popup's search filter, keeps
working untouched.

Accept only what you actually implement. A chord you accept but cannot act on is
worse than not binding it: it silently dies instead of reaching the popup.

### Working with clones

If the user already cloned the plugin you are targeting, its id differs. Resolve
it through the manifest. `PluginRegistry` honors `omarchy.clonedFrom`
generically, not just for the clone script:

```qml
var m = pluginRegistry.installedPlugins[pluginId]
var original = m && m.omarchy ? String(m.omarchy.clonedFrom || "") : ""
```

Declaring `clonedFrom` in *your own* manifest also makes the shell treat your
plugin as a replacement for the built-in it names. It inherits the IPC identity
so `omarchy menu summon` and existing keybindings keep working, and the built-in
is auto-disabled. Useful, but it means you own that surface; prefer attaching.

## Pitfalls

**Your injected objects outlive you.** A child created under the popup is
parented to the *popup*, not to your service. All four of these popups set
`keepLoaded: true` in their manifests (an optional flag; closed panels are
otherwise unloaded), so disabling your plugin leaves your object alive and still
handling keys, and each re-enable adds another. A full plugin reload is
different: it unloads panels before services, so those children die with the
panel. Destroy them in `Component.onDestruction`, and sweep for
orphans before attaching. An orphan of your own making still reports
`focus: true` and the search will happily nest a new one under it.

**Only take focus for the popup that is actually open.** `panelLoaders` holds
every loaded popup, not the visible one. Attaching to all of them and calling
`forceActiveFocus()` unconditionally makes your own injected items fight each
other for focus several times a second, and whichever grabbed it last swallows
the keys, and the open popup then silently ignores them. Gate on real open state
the way the shell does in `isPluginOpen()`: trust the root's `opened` property,
and treat `openPanelIds` only as a fallback, since it is set before the loader
resolves.

**Beware binding to a function that reads an injected property.** `running:
anyOpen()` looked reasonable and never ran once: property injection happens
after the object is constructed, so on first evaluation `shell` was still null,
the function returned before touching it, and QML captured no dependency to
re-evaluate on. Either guard on the injected object itself (`running: !!shell`)
or drive the work from a signal.

**A destroyed QObject leaves an invalidated wrapper.** Touching a property on it
throws. Guard reads of anything you cached across a reload.

**`keepLoaded` plugins ignore hot-reload.** Saving under
`~/.config/omarchy/plugins/` normally reloads the plugin, but one already
instantiated with `keepLoaded: true` keeps its old copy. Symptom: your edit
appears to do nothing. `omarchy restart shell`.

**Run `omarchy plugin validate` before you publish.** It rejects symlinks and
checks reserved ids and entry-point existence. Note it is stricter than the
shell: `PluginRegistry.qml` performs no symlink check of its own, so passing at
load time does not mean the CLI will accept it.

**Do not put a `.git` inside a clone directory.** `omarchy plugin update` with no
id loops over every plugin dir containing `.git` and fetches `origin`; a
remote-less repo there makes that plugin's update fail and the whole command
exit nonzero, though the loop does continue to the others.

**Never `rm -rf` a clone.** Use `omarchy plugin remove`, or the built-in the
clone displaced stays stranded in `shell.json`'s `disabledPlugins` and that
surface disappears entirely.

## When this will not work

Shared code outside the plugin tree cannot be reached: `Ui/*.qml` (including
`PanelKeyCatcher.qml`, the key dispatcher behind the wifi, bluetooth, tailscale
and weather panels) and `Commons/*.qml`. Nothing in `~/.config` overrides those;
they need an upstream change.

Changes that must happen *inside* upstream's own logic, such as altering mid-function
behavior, rendering, or data flow, have nothing to call from outside. That is
the case where a fork is genuinely the answer, and where you want a
baseline/patched 3-way merge to carry it across updates rather than a patch
script that matches on code upstream may have moved.

## Failure mode

Attaching from the outside degrades better than a fork, but "fails safe" would
be too strong. If a future Omarchy restructures a popup so the handler is not
found, that surface keeps its stock behavior and the rest carry on, and nothing
can be left half-patched because nothing was patched.

The honest caveat: handler discovery is a heuristic. If a restructure leaves a
*different* visible focused item where the search looks, it can attach in the
wrong place and take focus from something that wanted it. Claiming a chord only
when its action actually runs limits the blast radius (a changed upstream API
means the key falls through to the popup rather than dying) but it does not
eliminate it. Test after a major Omarchy upgrade rather than assuming.
