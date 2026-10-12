import QtQuick
import Quickshell
import Quickshell.Io
import "Store.js" as Store

// The feed, mounted once for the shell. Omarchy builds a bar per monitor, so
// a Process on the widget would be one set of SSH connections per screen.
// Every Panel.qml is a view of this instead.
Item {
  id: service
  visible: false

  // Where panels that the shell does not hand this service to find it.
  Component.onCompleted: Store.set(service)
  Component.onDestruction: Store.clear(service)

  property var status: ({ ok: true, error: "", config: "", example: "", projects: [], message: null })
  property bool started: false
  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    return s.indexOf("file://") === 0 ? s.substring(7) : s
  }

  // What is on screen stays; only the trouble is added to it.
  function trouble(text) {
    var s = {}
    for (var k in status) s[k] = status[k]
    s.ok = false
    s.error = text
    status = s
    started = true
  }

  Process {
    id: feed
    running: true
    command: [service.pluginDir + "bin/job-queues"]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        // The feed keeps its lines well under this; see MAX_LINE there.
        if (line.length > 4194304) { service.trouble("The feed sent more than the panel can show"); return }
        try {
          var d = JSON.parse(String(line))
          if (d && typeof d === "object") { service.status = d; service.started = true; again.interval = 2000 }
        } catch (e) { }
      }
    }
    // It is not meant to end. Whatever it had unlocked is locked again by that.
    onExited: {
      service.trouble("The feed stopped; starting it again")
      again.start()
    }
  }

  // Started again after a pause that doubles while it keeps ending.
  Timer {
    id: again
    interval: 2000
    onTriggered: {
      interval = Math.min(interval * 2, 60000)
      feed.running = true
    }
  }

  // One environment by its id ("project/environment"), or all of them.
  function refresh(id) {
    if (!feed.running) return
    feed.write(id ? "refresh " + String(id).replace(/[\r\n]/g, " ") + "\n" : "refresh\n")
  }

  // request: { id, backend, op, list?, queue?, name? } — id names the environment;
  // the job a change is about travels as "job".
  // The directory is chosen in the desktop's file chooser.
  function addProject() {
    if (feed.running) feed.write("project add\n")
  }

  // Off the list; the project itself is not touched.
  function removeProject(name) {
    if (feed.running) feed.write("project remove " + String(name).replace(/[\r\n]/g, " ") + "\n")
  }

  // Whether the panel may change things in one environment, for a while. To
  // allow it, the feed wants the environment's name as the user typed it.
  function setWritable(id, on, typed) {
    if (!feed.running) return
    var where = String(id).replace(/[\r\n]/g, " ")
    feed.write(on ? "writable on " + where + " " + String(typed || "").replace(/\s/g, "") + "\n"
                  : "writable off " + where + "\n")
  }

  // What a Kamal config left to code: { id, host, user, port, service, role }.
  function setEnvironment(values) {
    if (feed.running) feed.write("environment set " + JSON.stringify(values).replace(/[\r\n]/g, " ") + "\n")
  }

  // The SSH key of an environment, picked in the desktop's file chooser;
  // the answer comes back as status.message.picked.
  function chooseKey(id) {
    if (feed.running) feed.write("key choose " + String(id).replace(/[\r\n]/g, " ") + "\n")
  }

  function act(request) {
    if (feed.running) feed.write("action " + JSON.stringify(request).replace(/[\r\n]/g, " ") + "\n")
  }
}
