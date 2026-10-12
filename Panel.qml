import QtQuick
import Quickshell
import Quickshell.Io
import "Store.js" as Store
import qs.Ui
import qs.Commons

// Sidekiq and Solid Queue of the Rails applications in
// ~/.config/omarchy/job-queues.json: what is queued, running, failed and
// scheduled, with retry, delete, pause and run-now. Fed by
// bin/omarchy-job-queues, one long-lived process that asks each server over
// SSH. Service.qml owns that process; this widget exists once per monitor and
// shows it. Styled like martin.rails-news: theme colours, stock qs.Ui parts.
Panel {
  id: root

  moduleName: "martin.job-queues"
  ipcTarget: "martin.job-queues"

  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(barForeground, 1.4)
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------- Data ----------
  readonly property var status: service ? service.status
    : ({ ok: true, error: "", config: "", example: "", projects: [], message: null })
  readonly property var projects: status.projects || []

  // Two choices: a project, and one of the environments it runs in. What was
  // asked for is kept as names, so it survives the projects being read
  // again; what is shown falls back to something that exists.
  property string wantProject: ""
  property string wantEnv: ""

  // "solid_queue" reads "Solid Queue": a backend is shown under its gem's name.
  function backendName(b) {
    return String(b || "").split("_").map(function(w) { return w.charAt(0).toUpperCase() + w.substring(1) }).join(" ")
  }
  readonly property var project: {
    for (var i = 0; i < projects.length; i++)
      if (projects[i].name === wantProject) return projects[i]
    return projects[0] || null
  }
  // The projects as the list shows them: failed jobs in the name, backend
  // and environments under it.
  readonly property var projectOptions: projects.map(function(p) {
    var failed = root.failedInProject(p, "")
    var lost = (p.envs || []).some(root.down)
    var short = (p.envs || []).some(function(e) { return e.missing && e.missing.length > 0 })
    var kinds = (p.backends || []).map(function(b) { return root.backendName(b) })
    var names = (p.envs || []).map(function(e) { return e.name })
    return {
      value: p.name,
      label: p.name + (failed > 0 ? "  ·  " + failed + " failed" : short ? "  ·  needs details" : lost ? "  ·  unreachable" : ""),
      description: kinds.concat(names.join(", ")).join("  ·  ")
    }
  })
  readonly property var envs: project ? project.envs || [] : []
  readonly property var target: {
    var fallback = null
    for (var i = 0; i < envs.length; i++) {
      if (envs[i].name === wantEnv) return envs[i]
      if (envs[i].production || !fallback) fallback = envs[i]
    }
    return fallback
  }
  readonly property string targetId: target ? target.id : ""
  // Whether anything may be changed there at all; see "writable" in the config.
  readonly property bool writable: !!(target && target.writable)
  onTargetIdChanged: { resetView(); unlocking = null; if (!choosing) form = null; freshen() }
  // An environment that could not be looked at and now can is looked at.
  readonly property string targetError: target ? String(target.error || "") : ""
  onTargetErrorChanged: if (targetError === "") freshen()
  // The backend comes with the project. Should one ever have both, the
  // first that answered is shown.
  readonly property string backend: {
    var known = project ? project.backends || [] : []
    var data = target && target.data ? target.data : ({})
    for (var i = 0; i < known.length; i++) if (data[known[i]]) return known[i]
    return known[0] || ""
  }
  function resetView() { cursorIndex = 0; listView.contentY = 0; expanded = ""; copied = "" }

  // A job's arguments and error can be long: a click on the row unfolds
  // them, and Copy there puts the error on the clipboard.
  property string expanded: ""
  property string copied: ""
  function toggleRow(row) {
    if (!row || !row.key) return
    expanded = expanded === row.key ? "" : row.key
    copied = ""
  }
  function copyRow(row) {
    if (!row || !row.key || !row.error || copier.running) return
    copier.text = row.error
    copier.stdinEnabled = true
    copier.running = true
    copied = row.key
  }
  // On stdin, not as an argument: what a job failed with is nobody else's business.
  Process {
    id: copier
    property string text: ""
    command: ["/usr/bin/wl-copy"]
    stdinEnabled: true
    onStarted: { write(text); stdinEnabled = false }
  }

  readonly property var info: target && target.data && target.data[backend] ? target.data[backend] : null
  readonly property var stats: info && info.stats ? info.stats : ({})
  readonly property var lists: info && info.lists ? info.lists : []
  readonly property bool loading: !service || !service.started || !!(target && target.loading)

  // Failed jobs of an environment, in one backend or (without one) in all.
  function failedIn(env, only) {
    var n = 0
    var data = env && env.data ? env.data : ({})
    for (var b in data)
      if ((!only || b === only) && data[b] && data[b].stats) n += Number(data[b].stats.failed || 0)
    return n
  }
  // The same for a project, leaving out what runs on this machine.
  function failedInProject(p, only) {
    var n = 0
    var list = p ? p.envs || [] : []
    for (var i = 0; i < list.length; i++) if (!list[i].dev) n += failedIn(list[i], only)
    return n
  }
  function down(env) { return !!env && !env.ok && !env.loading && !env.dev }

  readonly property int failedTotal: {
    var n = 0
    for (var i = 0; i < projects.length; i++) n += failedInProject(projects[i], "")
    return n
  }
  readonly property int unreachable: {
    var n = 0
    for (var i = 0; i < projects.length; i++) n += (projects[i].envs || []).filter(root.down).length
    return n
  }

  // ---------- Tabs ----------
  readonly property var tabs: {
    var out = [{ key: "queues", label: "Queues", count: -1 }]
    for (var i = 0; i < lists.length; i++)
      out.push({ key: "list:" + lists[i].key, label: lists[i].label, count: Number(lists[i].total || 0) })
    out.push({ key: "cron", label: "Cron", count: info && info.cron ? info.cron.length : 0 })
    return out
  }
  property string tab: "queues"
  onTabsChanged: if (!tabs.some(function(t) { return t.key === root.tab })) tab = "queues"
  onTabChanged: resetView()

  readonly property var currentList: {
    if (tab.indexOf("list:") !== 0) return null
    for (var i = 0; i < lists.length; i++) if ("list:" + lists[i].key === tab) return lists[i]
    return null
  }

  function has(list, name) { return (list || []).indexOf(name) >= 0 }

  function timeAgo(epoch) {
    if (!epoch) return ""
    var d = Math.floor(Date.now() / 1000) - Number(epoch)
    var s = Math.abs(d)
    var t = s < 90 ? Math.max(1, Math.round(s)) + " s"
      : s < 3600 ? Math.round(s / 60) + " min"
      : s < 86400 ? Math.round(s / 3600) + " h"
      : Math.round(s / 86400) + " d"
    return d < 0 ? "in " + t : t + " ago"
  }

  function seconds(n) {
    if (n === null || n === undefined) return ""
    n = Number(n)
    return n < 90 ? Math.round(n) + " s" : n < 5400 ? Math.round(n / 60) + " min" : Math.round(n / 3600) + " h"
  }

  // One shape for every tab: a title, up to two lines under it, and the
  // buttons at the right edge. An action is { icon, tip, danger, request,
  // ask }, where `request` goes to the server and `ask` is the question put
  // first when it throws something away.
  readonly property var rows: {
    var out = []
    if (!info) return out
    var i
    if (tab === "queues") {
      var queues = info.queues || []
      for (i = 0; i < queues.length; i++) {
        var q = queues[i]
        var qa = []
        if (has(q.actions, "pause")) qa.push({
          icon: q.paused ? "\u{f040a}" : "\u{f03e4}", tip: q.paused ? "Resume" : "Pause", danger: false,
          request: { op: "pause_queue", queue: q.name }, ask: "" })
        if (has(q.actions, "clear")) qa.push({
          icon: "\u{f00e2}", tip: "Remove every job", danger: true,
          request: { op: "clear_queue", queue: q.name },
          ask: "Remove all " + q.size + " jobs waiting in " + q.name + "?" })
        out.push({
          title: q.name + (q.paused ? "  ·  paused" : ""),
          sub: q.size + " waiting" + (q.latency !== null && q.size > 0 ? "  ·  oldest " + seconds(q.latency) : ""),
          error: "", dim: false, actions: qa })
      }
      var procs = info.processes || []
      for (i = 0; i < procs.length; i++) {
        var p = procs[i]
        var bits = [p.kind]
        if (p.busy !== null && p.concurrency) bits.push(p.busy + " of " + p.concurrency + " busy")
        else if (p.concurrency) bits.push(p.concurrency + " threads")
        if (p.queues) bits.push(p.queues)
        if (p.beat) bits.push("seen " + timeAgo(p.beat))
        out.push({ title: p.name, sub: bits.join("  ·  "), error: "", dim: true, actions: [] })
      }
    }
    else if (tab === "cron") {
      var cron = info.cron || []
      for (i = 0; i < cron.length; i++) {
        var c = cron[i]
        var ca = []
        if (has(c.actions, "run")) ca.push({
          icon: "\u{f040a}", tip: "Run now", danger: false,
          request: { op: "cron_run", name: c.name }, ask: "" })
        if (has(c.actions, "toggle")) ca.push({
          icon: c.enabled ? "\u{f03e4}" : "\u{f0459}", tip: c.enabled ? "Disable" : "Enable", danger: false,
          request: { op: "cron_toggle", name: c.name }, ask: "" })
        out.push({
          title: c.name + (c.enabled ? "" : "  ·  disabled"),
          sub: c.schedule + "  ·  " + c.cls + (c.last ? "  ·  ran " + timeAgo(c.last) : ""),
          error: "", dim: !c.enabled, actions: ca })
      }
    }
    else if (currentList) {
      var items = currentList.items || []
      var key = currentList.key
      for (i = 0; i < items.length; i++) {
        var j = items[i]
        var ja = []
        if (has(currentList.actions, "retry")) ja.push({
          icon: "\u{f0459}", tip: key === "scheduled" ? "Run now" : "Retry", danger: false,
          request: { op: "retry", list: key, job: j.id }, ask: "" })
        if (has(currentList.actions, "delete")) ja.push({
          icon: "\u{f01b4}", tip: "Delete", danger: true,
          request: { op: "delete", list: key, job: j.id }, ask: "Delete " + j.cls + "?" })
        var meta = [j.queue]
        if (j.at) meta.push(timeAgo(j.at))
        if (j.tries) meta.push(j.tries + " tries")
        out.push({
          key: key + ":" + j.id, title: j.cls, meta: meta.join("  ·  "), args: j.args && j.args !== "[]" ? j.args : "",
          sub: meta.join("  ·  ") + (j.args && j.args !== "[]" ? "  ·  " + j.args : ""),
          error: j.error || "", dim: false, actions: ja })
      }
    }
    // A read-only environment is only looked at: no buttons to press.
    if (!writable) for (i = 0; i < out.length; i++) out[i].actions = []
    return out
  }

  // What the buttons under the list do to all of it.
  readonly property var bulk: {
    var out = []
    if (!writable || !currentList || !Number(currentList.total)) return out
    var n = currentList.total
    var what = n + " " + String(currentList.label).toLowerCase() + " job" + (n === 1 ? "" : "s")
    if (has(currentList.actions, "retry_all")) out.push({
      key: "retry_all", label: "Retry all", icon: "\u{f0459}",
      request: { op: "retry_all", list: currentList.key }, ask: "Retry all " + what + "?" })
    if (has(currentList.actions, "delete_all")) out.push({
      key: "delete_all", label: "Delete all", icon: "\u{f01b4}",
      request: { op: "delete_all", list: currentList.key }, ask: "Delete all " + what + "?" })
    return out
  }

  readonly property var message: {
    var m = status.message
    // Without an id it is about the list of projects; with one, about that
    // environment, and with a backend about a change made in it.
    return m && m.text && (m.id === "" || (m.id === targetId && (m.backend === "" || m.backend === backend))) ? m : null
  }

  // A project that was just added is the one to look at.
  readonly property var notice: status.message
  property real noticeSeen: 0
  onNoticeChanged: if (notice && (notice.select || notice.picked) && notice.ts !== noticeSeen) {
    noticeSeen = notice.ts
    if (notice.select) {
      wantProject = notice.select
      if (notice.env) wantEnv = notice.env
    }
    // The key chosen as a file goes into the form that asked for it.
    if (notice.picked && notice.picked.key && form && form.id === notice.picked.id) setFormValue("key", notice.picked.key)
  }

  // ---------- Feed ----------
  // The feed is a shell service, not a child of this widget: a Process in
  // here would be one set of SSH connections per monitor.
  property var service: null

  function bindService() {
    if (service) return
    var host = bar && bar.shell ? bar.shell : null
    var s = host && typeof host.serviceFor === "function" ? host.serviceFor(moduleName) : null
    // A tray drawer hands its widgets a facade without their service; see Store.js.
    if (!s) s = Store.get()
    if (!s) return
    service = s
  }

  // Polled: serviceFor() is a call, so nothing notifies a binding.
  Timer {
    interval: 100
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.bindService()
  }

  function refresh() {
    if (service) service.refresh(targetId)
  }

  // The servers are asked only for what is being looked at: the chosen
  // environment, when the panel opens or the choice changes, unless what is
  // known of it is fresh.
  function freshen() {
    if (opened && target && !target.loading && Date.now() / 1000 - Number(target.updated || 0) > 20) refresh()
  }

  // ---------- Actions ----------
  // A change waiting for a yes. Everything is asked about on a target marked
  // as production; elsewhere only what cannot be taken back.
  property var pending: null

  function request(action) {
    if (!service || !target || !action || !writable) return
    var req = { id: targetId, backend: backend }
    for (var k in action.request) req[k] = action.request[k]
    var question = action.ask || (target.production ? action.tip + "?" : "")
    if (question === "") { service.act(req); return }
    pending = { request: req, ask: question + "\n" + project.name + " " + target.name,
                confirm: action.danger ? "Delete" : "Yes" }
    confirm.selectedIndex = 0
  }

  function confirmPending() {
    if (pending && service) {
      if (pending.remove) service.removeProject(pending.remove)
      else service.act(pending.request)
    }
    pending = null
  }

  // The chooser is a window of its own, so the panel steps aside for it.
  function addProject() {
    if (!service) return
    service.addProject()
    close()
  }

  // Read-only is given up on purpose: the environment's name has to be
  // typed out, which no stray click or key does. Going back takes a click.
  // Deliberately without a key of its own.
  property var unlocking: null    // { id, name, project } while the name is asked for
  property string typed: ""
  readonly property bool typedRight: unlocking !== null && typed === unlocking.name
  function toggleWritable() {
    if (!service || !target || target.dev) return
    if (writable) { service.setWritable(targetId, false); return }
    typed = ""
    unlocking = { id: targetId, name: target.name, project: project.name }
  }
  function confirmUnlock() {
    if (!typedRight || !service) return
    service.setWritable(unlocking.id, true, typed)
    unlocking = null
  }
  // The keys of the name, one at a time; nothing here reads the clipboard.
  function typeKey(event) {
    if (event.key === Qt.Key_Escape) unlocking = null
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) confirmUnlock()
    else if (event.key === Qt.Key_Backspace) typed = typed.slice(0, -1)
    else if (event.text && event.text.length === 1 && event.text >= " " && typed.length < 64
             && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) typed += event.text
    event.accepted = true
  }

  // What a Kamal config leaves to code cannot be read from it, so it is
  // asked for here and kept in the plugin's config. Typed like the name
  // above: one field at a time, nothing pasted.
  readonly property var formFields: [
    { key: "host", label: "Server", hint: "address or name" },
    { key: "user", label: "SSH user", hint: "" },
    { key: "port", label: "SSH port", hint: "" },
    { key: "service", label: "Service", hint: "as in the Kamal config" },
    { key: "role", label: "Role", hint: "the one that runs the jobs" },
    { key: "proxy", label: "Jump host", hint: "optional: user@host", optional: true },
    { key: "key", label: "SSH key", hint: "optional: path to the key", optional: true }
  ]
  property var form: null         // { id, name, project, values, need } while it is filled in
  property int formFocus: 0
  readonly property bool formFull: {
    if (!form) return false
    for (var i = 0; i < formFields.length; i++) if (formLacks(formFields[i])) return false
    return true
  }
  // An optional field is needed only where the Kamal config has it, as code.
  function formLacks(field) {
    return !!form && !form.values[field.key] && (!field.optional || form.need.indexOf(field.key) >= 0)
  }
  readonly property bool lacking: !!(target && target.missing && target.missing.length)
  function fillIn() {
    if (!target || !target.fields || !project) return
    var values = {}
    var first = -1
    for (var i = 0; i < formFields.length; i++) {
      values[formFields[i].key] = String(target.fields[formFields[i].key] || "")
      if (first < 0 && !values[formFields[i].key] && (target.missing || []).indexOf(formFields[i].key) >= 0) first = i
    }
    formFocus = Math.max(0, first)
    form = { id: targetId, name: target.name, project: project.name, values: values, need: target.missing || [] }
  }
  function setFormValue(key, value) {
    var values = {}
    for (var k in form.values) values[k] = form.values[k]
    values[key] = value
    form = { id: form.id, name: form.name, project: form.project, values: values, need: form.need }
  }
  // The chooser is a window of its own: the panel steps aside for it and
  // comes back with the form as it was.
  property bool choosing: false
  function chooseKey() {
    if (!form || !service) return
    choosing = true
    service.chooseKey(form.id)
    close()
  }
  function saveForm() {
    if (!formFull || !service) return
    var req = { id: form.id }
    for (var k in form.values) req[k] = form.values[k]
    service.setEnvironment(req)
    form = null
  }
  function formKey(event) {
    var key = formFields[formFocus].key
    var was = form.values[key]
    var now = was
    if (event.key === Qt.Key_Escape) { form = null; event.accepted = true; return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) saveForm()
    else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down) formFocus = (formFocus + 1) % formFields.length
    else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) formFocus = (formFocus + formFields.length - 1) % formFields.length
    else if (event.key === Qt.Key_Backspace) now = was.slice(0, -1)
    else if (event.text && event.text.length === 1 && event.text > " " && was.length < 200
             && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) now = was + event.text
    if (form && now !== was) setFormValue(key, now)
    event.accepted = true
  }

  // Minutes an unlocked environment has left; the clock only runs while it shows.
  property int clock: 0
  Timer { interval: 5000; repeat: true; running: root.opened && root.writable && !!root.target && !root.target.dev; onTriggered: root.clock++ }
  readonly property int minutesLeft: {
    clock
    var until = target ? Number(target.until || 0) : 0
    return until ? Math.max(1, Math.ceil((until - Date.now() / 1000) / 60)) : 0
  }

  function removeProject() {
    if (!project) return
    pending = { remove: project.name, confirm: "Remove",
                ask: "Remove " + project.name + " from the list?\nThe project itself is not touched." }
    confirm.selectedIndex = 0
  }

  // Where the projects are, in the editor; a missing file starts as the example.
  function editConfig() {
    if (!status.config) return
    Quickshell.execDetached(["/bin/sh", "-c",
      '[ -e "$1" ] || { umask 077; mkdir -p -- "$(dirname -- "$1")"; cp -- "$2" "$1"; }; ' +
      'exec /usr/bin/omarchy-launch-editor "$1"', "sh", String(status.config), String(status.example)])
    close()
  }

  // ---------- Keyboard cursor ----------
  property bool cursorActive: false
  property int cursorIndex: 0
  onRowsChanged: if (cursorIndex >= rows.length) cursorIndex = Math.max(0, rows.length - 1)

  function moveCursor(dx, dy) {
    if (pending) {
      if (dx !== 0) confirm.selectedIndex = confirm.selectedIndex === 0 ? 1 : 0
      return
    }
    if (dx !== 0) {
      var keys = tabs.map(function(t) { return t.key })
      tab = keys[(keys.indexOf(tab) + dx + keys.length) % keys.length]
    }
    else if (!cursorActive) { cursorActive = true; cursorIndex = 0 }
    else cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
  }

  // Enter does the first thing a row offers, x the one that deletes.
  function activateRow(danger) {
    var row = cursorActive ? rows[cursorIndex] : null
    if (!row) return
    for (var i = 0; i < row.actions.length; i++)
      if (row.actions[i].danger === danger) { request(row.actions[i]); return }
  }

  // The next of a row of choices, for the keyboard.
  function cycle(names, current) {
    return names.length ? names[(names.indexOf(current) + 1) % names.length] : ""
  }
  function nextEnv() {
    wantEnv = cycle(envs.map(function(e) { return e.name }), target ? target.name : "")
  }

  onOpenedChanged: {
    pending = null
    unlocking = null
    if (!choosing) form = null
    if (opened) choosing = false
    if (!opened) { projectPicker.close(); return }
    cursorActive = false
    cursorIndex = 0
    freshen()
  }

  // ---------- Bar icon ----------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f0328}" // nf-md-layers
    active: root.failedTotal > 0 || root.unreachable > 0
    dimmed: !root.projects.length
    tooltipText: {
      if (!root.projects.length) return "Job Queues · " + (root.status.error || "starting")
      var parts = []
      for (var i = 0; i < root.projects.length; i++) {
        var p = root.projects[i]
        var failed = root.failedInProject(p, "")
        var lost = (p.envs || []).filter(root.down).map(function(e) { return e.name })
        if (failed > 0) parts.push(p.name + " " + failed + " failed")
        if (lost.length) parts.push(p.name + " " + lost.join(", ") + " unreachable")
      }
      return "Job Queues · " + (parts.length ? parts.join(" · ") : "click to look")
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.service) root.service.refresh("") }
      else root.toggle()
    }
  }

  // ---------- Pieces ----------
  // A number over what it counts.
  component Stat: Column {
    property string label: ""
    property var value: null
    property bool alarm: false
    visible: value !== null && value !== undefined
    spacing: Style.space(1)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: String(parent.value === null || parent.value === undefined ? "" : parent.value)
      color: parent.alarm ? root.urgent : root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: parent.label
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }
  }

  // One of a row of choices, with the failed jobs behind it.
  component Choice: Button {
    property int count: 0
    property bool alarm: false
    property string label: ""
    text: label + (count > 0 ? "  " + count : alarm ? "  !" : "")
    fontSize: Style.font.bodySmall
    foreground: alarm ? root.urgent : root.barForeground
    fontFamily: root.ff
    bordered: true
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
  }

  // One queue, job, process or recurring task.
  component EntryRow: Rectangle {
    id: row
    property var entry: ({})
    property bool hasCursor: false
    readonly property bool hot: rowMouse.containsMouse || hasCursor
    readonly property bool unfolded: !!entry.key && root.expanded === entry.key

    width: parent ? parent.width : 0
    implicitHeight: rowText.implicitHeight + Style.spacing.controlPaddingY * 2
    radius: Style.space(4)
    color: hot ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: row.entry.key ? Qt.LeftButton : Qt.NoButton
      cursorShape: row.entry.key ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.toggleRow(row.entry)
    }

    Column {
      id: rowText
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.right: rowActions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.entry.title || ""
        elide: Text.ElideRight
        color: row.entry.dim ? root.dimForeground : root.barForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
        font.bold: !row.entry.dim
      }

      Text {
        visible: text !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: (row.unfolded ? row.entry.meta : row.entry.sub) || ""
        elide: Text.ElideRight
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: row.unfolded && text !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: row.entry.args || ""
        wrapMode: Text.WrapAnywhere
        color: root.barForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: text !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: row.entry.error || ""
        wrapMode: Text.WrapAnywhere
        maximumLineCount: row.unfolded ? 60 : 2
        elide: Text.ElideRight
        color: root.urgent
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: row.unfolded && !!row.entry.error
        textFormat: Text.PlainText
        text: root.copied === row.entry.key ? "\u{f012c}  Copied" : "\u{f018f}  Copy error" // nf-md-check, nf-md-content_copy
        color: copyMouse.containsMouse ? root.barForeground : root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
        topPadding: Style.space(2)

        MouseArea {
          id: copyMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.copyRow(row.entry)
        }
      }
    }

    Row {
      id: rowActions
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Repeater {
        model: row.entry.actions || []
        PanelActionButton {
          required property var modelData
          iconText: modelData.icon
          tooltipText: modelData.tip
          foreground: root.barForeground
          hoverColor: modelData.danger ? root.urgent : root.barForeground
          fontFamily: root.ff
          onClicked: root.request(modelData)
        }
      }
    }
  }

  // ---------- Panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(720))
    // A short list must not cut off the dialog that is open over it.
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight,
      root.form !== null ? formColumn.implicitHeight + Style.space(68) : 0,
      root.unlocking !== null ? unlockColumn.implicitHeight + Style.space(68) : 0))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true
      // The project list has a search field; typing belongs to it.
      // So does typing an environment's name to unlock it.
      blocked: projectPicker.popupOpen || root.unlocking !== null || root.form !== null
      Keys.onPressed: function(event) {
        if (root.unlocking !== null) root.typeKey(event)
        else if (root.form !== null) root.formKey(event)
      }
      onCloseRequested: root.pending ? root.pending = null : root.close()
      onTabRequested: function(direction) { if (!root.pending) root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: {
        if (!root.pending) root.activateRow(false)
        else if (confirm.selectedIndex === 1) root.confirmPending()
        else root.pending = null
      }
      onDeleteRequested: if (!root.pending) root.activateRow(true)
      onTextKey: function(t) {
        if (root.pending) return
        if (t === "r" || t === "R") root.refresh()
        else if (t === "p" || t === "P") projectPicker.open()
        else if (t === "a" || t === "A") root.addProject()
        else if (t === "e" || t === "E") root.nextEnv()
        else if (t === "c" || t === "C") root.editConfig()
        else if (t === "o" || t === "O") root.toggleRow(root.cursorActive ? root.rows[root.cursorIndex] : null)
        else if (t === "y" || t === "Y") root.copyRow(root.cursorActive ? root.rows[root.cursorIndex] : null)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------- Masthead ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(masthead.implicitHeight, edition.implicitHeight)

          PanelSectionHeader {
            id: masthead
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "JOB QUEUES"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          Text {
            id: edition
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: {
              if (!root.target) return ""
              var bits = []
              if (root.backend) bits.push((root.backendName(root.backend))
                + (root.info && root.info.version ? " " + root.info.version : ""))
              if (root.info && root.info.env && root.info.env !== root.target.name) bits.push("RAILS_ENV " + root.info.env)
              bits.push(!root.writable ? "read-only" : root.target.dev ? "" : "changes allowed for " + root.minutesLeft + " min")
              bits.push(root.loading ? "loading…" : root.target.updated ? root.timeAgo(root.target.updated) : "")
              return bits.filter(function(b) { return b !== "" }).join("  ·  ")
            }
            color: root.dimForeground
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Project, environment ----------
        // There may be many projects, so they are a list to search in; the
        // few environments of the chosen one are buttons beside it.
        Row {
          id: chooser
          width: parent.width
          spacing: Style.space(10)

          SearchableDropdown {
            id: projectPicker
            width: Math.min(Style.space(260), parent.width / 2)
            anchors.verticalCenter: parent.verticalCenter
            showLabel: false
            placeholderText: "Search projects…"
            emptyText: "No such project"
            fontFamily: root.ff
            foreground: root.barForeground
            value: root.project ? root.project.name : ""
            options: root.projectOptions
            // The dropdown assigns its value when one is picked, which would
            // leave it showing that pick whatever is chosen from elsewhere.
            onChanged: function(name) {
              root.wantProject = name
              value = Qt.binding(function() { return root.project ? root.project.name : "" })
            }
          }

          Flow {
            width: parent.width - projectPicker.width - chooser.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Repeater {
              model: root.envs.length
              Choice {
                required property int index
                readonly property var e: root.envs[index] || ({})
                label: e.name || ""
                count: root.failedIn(e, "")
                alarm: count > 0 || root.down(e)
                selected: root.targetId === e.id
                onClicked: root.wantEnv = e.name
              }
            }
          }
        }

        // ---------- Nothing to show ----------
        Text {
          visible: text !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: !root.projects.length
              ? (root.status.error ? root.status.error + ". Press Add project to list one." : "Starting…")
            : root.status.error ? root.status.error   // the feed itself is in trouble
            : !root.target ? (root.project ? root.project.note || "" : "")
            : root.target.error ? root.target.error
            : !root.info ? "Loading…" : ""
          color: (root.projects.length && root.status.error) || (root.target && root.target.error && !root.target.dev)
               ? root.urgent : root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: root.lacking
          text: "Fill in"
          iconText: "\u{f03eb}" // nf-md-pencil
          iconSize: Style.font.icon
          tooltipText: "Say what the Kamal config leaves to code; it is kept in the plugin's config"
          fontSize: Style.font.bodySmall
          foreground: root.barForeground
          fontFamily: root.ff
          bordered: true
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.fillIn()
        }

        // ---------- Numbers ----------
        Row {
          id: statRow
          visible: root.info !== null
          width: parent.width

          Repeater {
            model: [
              { label: "Queued", key: "enqueued" },
              { label: "Running", key: "busy" },
              { label: "Scheduled", key: "scheduled" },
              { label: "Retries", key: "retry" },
              { label: "Failed", key: "failed" },
              { label: "Workers", key: "processes" }
            ]
            Stat {
              required property var modelData
              width: statRow.width / 6
              label: modelData.label
              value: root.stats[modelData.key]
              alarm: (modelData.key === "failed" && Number(value) > 0) || (modelData.key === "processes" && Number(value) === 0)
            }
          }
        }

        // ---------- Tabs ----------
        Flow {
          id: tabRow
          visible: root.info !== null
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.tabs
            Button {
              required property var modelData
              text: modelData.label + (modelData.count > 0 ? "  " + modelData.count : "")
              selected: root.tab === modelData.key
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.tab = modelData.key
            }
          }
        }

        Text {
          visible: root.info !== null && !root.rows.length
          width: parent.width
          textFormat: Text.PlainText
          text: "Nothing here"
          color: root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Rows ----------
        // Scrolls when the list is taller than the screen leaves room for,
        // so the actions below stay in view.
        Flickable {
          id: listView
          visible: root.rows.length > 0
          width: parent.width
          height: Math.min(list.implicitHeight, Math.max(Style.space(120), panel.availableCardHeight - Style.space(330)))
          contentHeight: list.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          // Keep the row under the keyboard cursor in view.
          function reveal(row) {
            if (!row) return
            if (row.y < contentY) contentY = row.y
            else if (row.y + row.height > contentY + height) contentY = row.y + row.height - height
          }

          Column {
            id: list
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows.length
              EntryRow {
                required property int index
                entry: root.rows[index] || ({})
                hasCursor: root.cursorActive && root.cursorIndex === index
                onHasCursorChanged: if (hasCursor) listView.reveal(this)
              }
            }
          }
        }

        Text {
          visible: root.currentList !== null && Number(root.currentList.total) > root.rows.length
          width: parent.width
          textFormat: Text.PlainText
          text: root.currentList ? "Showing " + root.rows.length + " of " + root.currentList.total : ""
          color: root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        // ---------- The whole list ----------
        Row {
          id: bulkRow
          visible: root.bulk.length > 0
          spacing: Style.space(6)

          Repeater {
            model: root.bulk
            Button {
              required property var modelData
              iconText: modelData.icon
              iconSize: Style.font.icon
              text: modelData.label
              fontSize: Style.font.bodySmall
              foreground: modelData.key === "delete_all" ? root.urgent : root.barForeground
              fontFamily: root.ff
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.request({ request: modelData.request, ask: modelData.ask, tip: modelData.label,
                                        danger: modelData.key === "delete_all" })
            }
          }
        }

        // ---------- What the last change did ----------
        Text {
          visible: root.message !== null
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.message ? root.message.text + "  ·  " + root.timeAgo(root.message.ts) : ""
          color: root.message && !root.message.ok ? root.urgent : root.dimForeground
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        PanelSeparator {
          width: parent.width
          foreground: root.barForeground
        }

        // ---------- Actions ----------
        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)

          readonly property var entries: [
            { key: "add", label: "Add project", icon: "\u{f0257}", tip: "Choose a project's directory to list it here" }, // nf-md-folder_plus
            { key: "remove", label: "Remove project", icon: "\u{f0258}", tip: "Take the chosen project off this list; the project itself is not touched" }, // nf-md-folder_remove
            { key: "lock", label: "Allow changes", icon: "\u{f033f}", tip: "This environment is read-only: nothing can be changed in it from here. Click to allow changes for half an hour" }, // nf-md-lock_open
            { key: "config", label: "Config", icon: "\u{f0493}", tip: "Open job-queues.json in the editor" }, // nf-md-cog
            { key: "refresh", label: "Refresh", icon: "\u{f0450}", tip: "Load this environment again" } // nf-md-refresh
          ]

          Repeater {
            model: actionRow.entries
            Button {
              required property var modelData
              width: (actionRow.width - actionRow.spacing * (actionRow.entries.length - 1)) / actionRow.entries.length
              readonly property bool unlocked: modelData.key === "lock" && root.writable
              enabled: modelData.key === "lock" ? root.target !== null && !root.target.dev && !root.target.error
                     : modelData.key !== "remove" || root.project !== null
              opacity: enabled ? 1 : 0.4
              iconText: unlocked ? "\u{f033e}" : modelData.icon // nf-md-lock
              iconSize: Style.font.icon
              iconSpinning: modelData.key === "refresh" && root.loading && root.projects.length > 0
              // The button says what a click does; the state is in the header.
              text: !unlocked ? modelData.label : root.target.dev ? "Writable" : "Make read-only"
              tooltipText: modelData.key !== "lock" ? modelData.tip
                         : root.target && root.target.dev ? "Development is this machine and can always be changed"
                         : unlocked ? "Changes are allowed in this environment for a while. Click to make it read-only again now" : modelData.tip
              fontSize: Style.font.bodySmall
              foreground: unlocked && !root.target.dev ? root.urgent : root.barForeground
              fontFamily: root.ff
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                if (modelData.key === "add") root.addProject()
                else if (modelData.key === "remove") root.removeProject()
                else if (modelData.key === "lock") root.toggleWritable()
                else if (modelData.key === "config") root.editConfig()
                else root.refresh()
              }
            }
          }
        }
      }

      // Asks for what a Kamal config left to code.
      Rectangle {
        anchors.fill: parent
        z: 21
        visible: root.form !== null
        color: Util.alpha(Color.background, 0.7)

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: root.form = null }

        Rectangle {
          width: Math.min(parent.width - Style.space(32), Style.space(430))
          height: formColumn.implicitHeight + Style.space(36)
          anchors.centerIn: parent
          color: Color.popups.background
          border.color: root.accent
          border.width: Style.normalBorderWidth
          radius: Style.cornerRadius

          MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: {} }

          Column {
            id: formColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(18)
            spacing: Style.space(10)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.form ? "Reaching " + root.form.project + " " + root.form.name : ""
              color: Color.popups.text
              font.family: root.ff
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "The project's Kamal config works some of this out with code, which is not run here. "
                  + "What you type is kept in the plugin's config."
              color: root.dimForeground
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.formFields
              Item {
                id: field
                required property var modelData
                required property int index
                readonly property string value: root.form ? root.form.values[modelData.key] || "" : ""
                readonly property bool current: root.formFocus === index
                width: formColumn.width
                implicitHeight: box.height

                Text {
                  id: fieldLabel
                  width: Style.space(86)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: field.modelData.label
                  color: root.dimForeground
                  font.family: root.ff
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  id: pick
                  visible: field.modelData.key === "key"
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Choose"
                  tooltipText: "Pick the key in the file chooser"
                  fontSize: Style.font.bodySmall
                  foreground: Color.popups.text
                  fontFamily: root.ff
                  bordered: true
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.chooseKey()
                }

                Rectangle {
                  id: box
                  anchors.left: fieldLabel.right
                  anchors.right: pick.visible ? pick.left : parent.right
                  anchors.rightMargin: pick.visible ? Style.space(8) : 0
                  height: fieldText.implicitHeight + Style.spacing.controlPaddingY * 2
                  color: "transparent"
                  border.color: field.current ? root.accent : root.formLacks(field.modelData) ? root.urgent : Util.alpha(Color.popups.text, 0.38)
                  border.width: Style.normalBorderWidth

                  Text {
                    id: fieldText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Style.spacing.controlPaddingX
                    textFormat: Text.PlainText
                    elide: Text.ElideLeft
                    text: field.current ? field.value + "\u2581" : field.value !== "" ? field.value : field.modelData.hint
                    color: field.value !== "" || field.current ? Color.popups.text : root.dimForeground
                    font.family: root.ff
                    font.pixelSize: Style.font.body
                  }

                  MouseArea { anchors.fill: parent; onClicked: root.formFocus = field.index }
                }
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(10)

              Button {
                text: "Cancel"
                fontSize: Style.font.bodySmall
                foreground: Color.popups.text
                fontFamily: root.ff
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.form = null
              }

              Button {
                text: "Save"
                enabled: root.formFull
                opacity: enabled ? 1 : 0.4
                fontSize: Style.font.bodySmall
                foreground: root.accent
                fontFamily: root.ff
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.saveForm()
              }
            }
          }
        }
      }

      // Asks for an environment's name before it is unlocked.
      Rectangle {
        anchors.fill: parent
        z: 21
        visible: root.unlocking !== null
        color: Util.alpha(Color.background, 0.7)

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: root.unlocking = null }

        Rectangle {
          width: Math.min(parent.width - Style.space(32), Style.space(430))
          height: unlockColumn.implicitHeight + Style.space(36)
          anchors.centerIn: parent
          color: Color.popups.background
          border.color: root.urgent
          border.width: Style.normalBorderWidth
          radius: Style.cornerRadius

          MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: {} }

          Column {
            id: unlockColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(18)
            spacing: Style.space(12)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.unlocking ? "Allow changes in " + root.unlocking.project + " " + root.unlocking.name + "?" : ""
              color: Color.popups.text
              font.family: root.ff
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Retry, delete, pause and run-now will work from this panel for half an hour, "
                  + "or until you switch it back."
              color: root.dimForeground
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }

            // The name is its own Text so it can be bold without rich text.
            Row {
              width: parent.width
              spacing: 0

              Text {
                id: typeLead
                textFormat: Text.PlainText
                text: "Type "
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: Math.min(implicitWidth, parent.width - typeLead.width - typeTail.width)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: root.unlocking ? root.unlocking.name : ""
                color: root.urgent
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                id: typeTail
                textFormat: Text.PlainText
                text: " to go on."
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }
            }

            Rectangle {
              width: parent.width
              height: typedText.implicitHeight + Style.spacing.controlPaddingY * 2
              color: "transparent"
              border.color: root.typedRight ? root.accent : Util.alpha(Color.popups.text, 0.38)
              border.width: Style.normalBorderWidth

              Text {
                id: typedText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.spacing.controlPaddingX
                textFormat: Text.PlainText
                elide: Text.ElideLeft
                text: root.typed + "\u2581"
                color: Color.popups.text
                font.family: root.ff
                font.pixelSize: Style.font.body
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(10)

              Button {
                text: "Cancel"
                fontSize: Style.font.bodySmall
                foreground: Color.popups.text
                fontFamily: root.ff
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.unlocking = null
              }

              Button {
                text: "Allow changes"
                enabled: root.typedRight
                opacity: enabled ? 1 : 0.4
                fontSize: Style.font.bodySmall
                foreground: root.urgent
                fontFamily: root.ff
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.confirmUnlock()
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 20
        opened: root.pending !== null
        message: root.pending ? root.pending.ask : ""
        confirmText: root.pending ? root.pending.confirm : "Yes"
        background: Color.popups.background
        foreground: Color.popups.text
        selectedText: root.accent
        fontFamily: root.ff
        cornerRadius: Style.cornerRadius
        onCanceled: root.pending = null
        onConfirmed: root.confirmPending()
      }
    }
  }
}
