import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The single night light brain, one per shell however many bars are showing the
// button. It owns the settings and the schedule, and is the only part of the
// plugin that talks to hyprsunset.
//
// Scheduled changes are edge-triggered: the screen is only set when the plan
// changes or hyprsunset restarts, so `omarchy toggle nightlight` or a hand-typed
// hyprctl command stays put until the next scheduled change.
Item {
  id: root

  readonly property int minTemp: Model.MIN_TEMP
  readonly property int maxTemp: Model.MAX_TEMP
  readonly property int previewMilliseconds: 10000
  readonly property string home: Quickshell.env("HOME")
  readonly property string settingsDirectory: home + "/.local/state/omarchy/settings"
  readonly property string settingsPath: settingsDirectory + "/heliotrope.json"

  // The icon asks for the panel through here; Panel.qml answers.
  signal panelToggleRequested(var window)
  // The icon holds the bar's hover peek open while this is true.
  property bool panelOpen: false

  property var settings: Model.normalizeSettings(null)
  property bool settingsLoaded: false
  property bool directoryReady: false
  property bool settingsSecured: false

  property var weather: null
  property string zone: ""
  property var zoneLocation: null
  readonly property var location: Model.resolveLocation(settings, weather, zoneLocation)
  // Nothing happens to the screen until these have answered, or a restart at
  // night would briefly clear the tint while the location loads.
  property bool weatherChecked: false
  property bool zoneNameChecked: false
  property bool zoneTableChecked: false
  readonly property bool locationChecked: weatherChecked && zoneNameChecked && zoneTableChecked

  property var plan: ({ on: false, until: 0 })
  property real sunrise: 0
  property real sunset: 0

  // What hyprsunset last reported; null while it is not answering.
  property var actualTemp: null
  // Tinting while the plan says off, so it can be seen. Clears by itself.
  property bool previewing: false

  property var lastPlanOn: null
  property int applyTarget: 0
  property bool applySettled: true
  property int applyAttempts: 0
  property int queuedTarget: 0
  property real lastStartAttempt: 0

  readonly property bool nightOn: actualTemp !== null && actualTemp < Model.FRESH_TEMP
  readonly property bool switchOn: nightOn && !previewing
  readonly property string mode: settings.mode
  readonly property int temperature: settings.temperature
  readonly property string onTime: settings.onTime
  readonly property string offTime: settings.offTime

  function updateSettings(patch) {
    // Saving before the file has loaded would replace it with the defaults.
    if (!settingsLoaded) {
      console.warn("io.github.williamjohndavisiii.heliotrope: settings not loaded yet, ignoring change")
      return
    }
    var next = {}
    for (var key in settings) next[key] = settings[key]
    for (var changed in patch) next[changed] = patch[changed]
    settings = Model.normalizeSettings(next)
    settingsFile.setText(JSON.stringify(settings, null, 2) + "\n")
    tick()
  }

  function setMode(value) {
    updateSettings(Model.modePatch(settings, value, switchOn))
  }

  function setSwitch(turnOn) {
    if (!settingsLoaded) return
    previewTimer.stop()
    previewing = false
    updateSettings(Model.switchPatch(settings, location, Date.now(), turnOn))
    // Also covers a switch that already matched the plan, like after the menu's toggle.
    apply(plan.on ? temperature : Model.OFF_TEMP)
  }

  function preview(kelvin) {
    if (!settingsLoaded) return
    var clamped = Model.clampTemp(kelvin)
    if (plan.on) {
      previewing = false
    } else {
      previewing = true
      previewTimer.restart()
    }
    apply(clamped)
  }

  function setTemperature(kelvin) {
    var clamped = Model.clampTemp(kelvin)
    updateSettings({ temperature: clamped })
    preview(clamped)
  }

  // True when saved. Empty text goes back to the automatic location.
  function setLocation(text) {
    if (String(text).trim() === "") {
      updateSettings({ latitude: null, longitude: null })
      return true
    }
    var place = Model.parseCoordinates(text)
    if (!place) return false
    updateSettings({ latitude: place.latitude, longitude: place.longitude })
    return true
  }

  function setTime(key, text) {
    var patch = {}
    patch[key] = text
    updateSettings(patch)
  }

  function stepTime(key, deltaMinutes) {
    setTime(key, Model.stepTime(key === "onTime" ? onTime : offTime, deltaMinutes))
  }

  function endPreview() {
    if (!previewing) return
    previewTimer.stop()
    previewing = false
    apply(plan.on ? temperature : Model.OFF_TEMP)
  }

  function tick() {
    if (!settingsLoaded || !locationChecked) return
    var now = Date.now()
    if (settings.override && now >= settings.override.until) {
      updateSettings({ override: null })
      return
    }

    // The next of each, so the panel agrees with "on until" after today's has passed.
    if (location) {
      var today = Model.sunTimes(now, location.latitude, location.longitude)
      var tomorrow = Model.sunTimes(now + 86400000, location.latitude, location.longitude)
      sunrise = now < today.sunrise ? today.sunrise : tomorrow.sunrise
      sunset = now < today.sunset ? today.sunset : tomorrow.sunset
    } else {
      sunrise = 0
      sunset = 0
    }
    plan = Model.desiredState(settings, location, now)

    if (lastPlanOn !== plan.on) {
      lastPlanOn = plan.on
      previewTimer.stop()
      previewing = false
      apply(plan.on ? temperature : Model.OFF_TEMP)
    }
    if (!probeProcess.running) probeProcess.running = true
  }

  function apply(kelvin) {
    applyTarget = kelvin
    applySettled = false
    applyAttempts = 0
    if (actualTemp !== null || kelvin < Model.FRESH_TEMP) actualTemp = kelvin
    runApply()
  }

  function runApply() {
    if (applyProcess.running) {
      queuedTarget = applyTarget
      return
    }
    // Even 6500K tints the screen, so off also restores the identity matrix.
    var target = Number(applyTarget)
    applyProcess.command = ["bash", "-c",
      "hyprctl hyprsunset temperature " + target
      + (target === Model.OFF_TEMP ? " && hyprctl hyprsunset identity" : "")]
    applyProcess.running = true
  }

  function handleProbe(text) {
    var trimmed = String(text).trim()
    var reported = /^[0-9]+$/.test(trimmed) ? Number(trimmed) : null
    if (applyProcess.running || queuedTarget) return

    if (reported === null) {
      actualTemp = null
      if (plan.on || previewing) {
        // Not running, and needed. Starting it only when needed keeps days free of it.
        var now = Date.now()
        if (now - lastStartAttempt > 10000) {
          lastStartAttempt = now
          Quickshell.execDetached(["uwsm-app", "--", "hyprsunset"])
        }
        applySettled = false
        applyTarget = previewing ? applyTarget : temperature
        applyAttempts++
        if (applyAttempts % 5 === 0 && applyAttempts <= 30) runApply()
      } else {
        applySettled = true
      }
      return
    }

    actualTemp = reported
    if (reported === Model.FRESH_TEMP) {
      // hyprsunset just restarted, which drops whatever was set before.
      apply(plan.on ? temperature : Model.OFF_TEMP)
    } else if (!applySettled && reported === applyTarget) {
      applySettled = true
    } else if (!applySettled && applyAttempts < 30) {
      applyAttempts++
      runApply()
    }
  }

  function loadSettings(text) {
    // Newly created by settingsSetup: fill it in, keeping anything already in memory.
    if (String(text).trim() === "") {
      settingsLoaded = true
      updateSettings({})
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.warn("io.github.williamjohndavisiii.heliotrope: ignoring unreadable settings file")
    }
    var next = Model.normalizeSettings(parsed)
    var changed = JSON.stringify(next) !== JSON.stringify(settings)
    settings = next
    settingsLoaded = true
    if (changed || lastPlanOn === null) tick()
  }

  onLocationChanged: tick()
  onLocationCheckedChanged: tick()

  // The settings can hold private coordinates, so the file is owner-only before
  // anything is saved to it. Saves replace the file but keep its permissions, and
  // this also tightens a file made by an earlier version.
  Process {
    id: settingsSetup
    running: true
    command: ["sh", "-c", "mkdir -p \"$1\" && touch \"$2\" && chmod 600 \"$2\"",
      "heliotrope", root.settingsDirectory, root.settingsPath]
    onExited: function(exitCode) {
      root.settingsSecured = exitCode === 0
      if (!root.settingsSecured)
        console.warn("io.github.williamjohndavisiii.heliotrope: could not make the settings file private")
      root.directoryReady = true
    }
  }

  FileView {
    id: settingsFile
    path: root.directoryReady ? root.settingsPath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadSettings(text())
    onLoadFailed: function(error) {
      if (error !== FileViewError.FileNotFound) {
        console.warn("io.github.williamjohndavisiii.heliotrope: could not read settings: " + FileViewError.toString(error))
        return
      }
      // Deleted while running. A plain save would recreate it readable by others.
      if (root.settingsSecured) {
        root.settingsSecured = false
        root.directoryReady = false
        settingsSetup.running = true
        return
      }
      // Setup couldn't create it, so run on the defaults without saving a new file.
      root.settingsLoaded = true
      root.tick()
    }
  }

  // Omarchy's own location, which owns this file's format (omarchy-weather-location).
  FileView {
    path: root.settingsDirectory + "/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.weather = Model.weatherLocation(text())
      root.weatherChecked = true
    }
    onLoadFailed: function() {
      root.weather = null
      root.weatherChecked = true
    }
  }

  FileView {
    id: zoneTable
    path: "/usr/share/zoneinfo/zone1970.tab"
    printErrors: false
    onLoaded: {
      root.zoneLocation = Model.zoneCoordinates(text(), root.zone)
      root.zoneTableChecked = true
    }
    onLoadFailed: function() { root.zoneTableChecked = true }
  }

  Process {
    running: true
    command: ["readlink", "-f", "/etc/localtime"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.zone = Model.zoneName(text)
        root.zoneLocation = Model.zoneCoordinates(zoneTable.text(), root.zone)
        root.zoneNameChecked = true
      }
    }
  }

  Process {
    id: applyProcess
    onExited: function() {
      if (root.queuedTarget) {
        root.queuedTarget = 0
        root.runApply()
        return
      }
      if (!probeProcess.running) probeProcess.running = true
    }
  }

  Process {
    id: probeProcess
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleProbe(text)
    }
  }

  Timer {
    id: previewTimer
    interval: root.previewMilliseconds
    onTriggered: root.endPreview()
  }

  // Checks quickly while a change is settling, like hyprsunset still starting.
  Timer {
    interval: root.applySettled || root.applyAttempts >= 30 ? 15000 : 1000
    running: root.settingsLoaded
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  ShellIpc {
    target: "io.github.williamjohndavisiii.heliotrope.control"

    function status(): string {
      return JSON.stringify({
        on: root.nightOn,
        switchOn: root.switchOn,
        temperature: root.actualTemp,
        savedTemperature: root.temperature,
        mode: root.mode,
        location: root.location ? root.location.source : "none",
        planOn: root.plan.on,
        until: root.plan.until ? new Date(root.plan.until).toLocaleString() : "",
        previewing: root.previewing,
        override: root.settings.override
      })
    }
    function on(): void { root.setSwitch(true) }
    function off(): void { root.setSwitch(false) }
    function toggle(): void { root.setSwitch(!root.switchOn) }
    function set(kelvin: int): void { root.setTemperature(kelvin) }
    function preview(kelvin: int): void { root.preview(kelvin) }
    function schedule(mode: string): void { root.setMode(mode) }
    function location(coordinates: string): string {
      return root.setLocation(coordinates) ? "ok" : "invalid"
    }
    function hours(onTime: string, offTime: string): void {
      root.updateSettings({ onTime: onTime, offTime: offTime })
    }
  }
}
