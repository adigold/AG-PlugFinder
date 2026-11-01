/// The add-on Ableton Live loads (BL-161), written to the User Library's Remote Scripts folder.
/// It listens on this Mac only (127.0.0.1) and does three things: answers a ping, loads a plugin
/// or device onto the selected track through Live's own browser, and lists the selected
/// track's devices. Nothing leaves the Mac.
enum AbletonScript {
    static let source = #"""
# AG PlugFinder add-on for Ableton Live. Installed by the AG PlugFinder app.
# Listens on 127.0.0.1 only, so only apps on this Mac can reach it.
import json
import socket

import Live
from _Framework.ControlSurface import ControlSurface

PORT = 47391
VERSION = 3


def _norm(text):
    return "".join(ch for ch in text.lower() if ch.isalnum())


class AGPlugFinder(ControlSurface):
    def __init__(self, c_instance):
        ControlSurface.__init__(self, c_instance)
        self._index = None
        self._sock = None
        try:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._sock.bind(("127.0.0.1", PORT))
            self._sock.setblocking(False)
        except Exception as e:
            self.log_message("AG PlugFinder: could not listen: %s" % e)
            self._sock = None
        self.schedule_message(1, self._poll)

    def disconnect(self):
        if self._sock is not None:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        ControlSurface.disconnect(self)

    # Requests arrive between Live's screen updates, about ten times a second.
    def _poll(self):
        if self._sock is None:
            return
        try:
            while True:
                data, addr = self._sock.recvfrom(65536)
                try:
                    reply = self._handle(json.loads(data.decode("utf-8")))
                except Exception as e:
                    reply = {"ok": False, "error": str(e)}
                self._sock.sendto(json.dumps(reply).encode("utf-8"), addr)
        except (BlockingIOError, OSError):
            pass
        self.schedule_message(1, self._poll)

    def _handle(self, msg):
        cmd = msg.get("cmd")
        if cmd == "ping":
            return {"ok": True, "version": VERSION}
        if cmd == "load":
            return self._load(msg)
        if cmd == "track":
            return self._track()
        if cmd == "pics_begin":
            return self._pics_begin()
        if cmd == "pics_load":
            return self._pics_load(msg)
        if cmd == "pics_end":
            return self._pics_end()
        return {"ok": False, "error": "Unknown request"}

    # Pictures of Live's devices: a spare track, one device at a time, removed at the end.
    PICS = "AGPF pictures"

    def _pics_track(self):
        for t in self.song().tracks:
            if t.name == self.PICS:
                return t
        return None

    def _pics_begin(self):
        song = self.song()
        track = self._pics_track()
        if track is None:
            song.create_midi_track(-1)
            track = song.tracks[len(song.tracks) - 1]
            track.name = self.PICS
        song.view.selected_track = track
        view = Live.Application.get_application().view
        view.show_view("Detail")
        view.show_view("Detail/DeviceChain")
        return {"ok": True}

    def _pics_clear(self, track):
        while len(track.devices) > 0:
            track.delete_device(0)

    def _pics_load(self, msg):
        track = self._pics_track()
        if track is None:
            return {"ok": False, "error": "No pictures track"}
        self.song().view.selected_track = track
        self._pics_clear(track)
        if not msg.get("name"):
            return {"ok": True}
        item = self._find(msg)
        if item is None:
            return {"ok": False, "error": "not found"}
        Live.Application.get_application().browser.load_item(item)
        return {"ok": True}

    def _pics_end(self):
        song = self.song()
        track = self._pics_track()
        if track is not None:
            song.delete_track(list(song.tracks).index(track))
        return {"ok": True}

    # Every loadable item under a browser folder, by its name without spaces or signs.
    def _walk(self, item, out, depth):
        if depth > 6:
            return
        for child in item.children:
            if child.is_loadable:
                out.setdefault(_norm(child.name), []).append(child)
            if child.is_folder or len(child.children) > 0:
                self._walk(child, out, depth + 1)

    def _build_index(self):
        browser = Live.Application.get_application().browser
        plugins, devices = {}, {}
        self._walk(browser.plugins, plugins, 0)
        for root in (browser.audio_effects, browser.instruments, browser.midi_effects):
            self._walk(root, devices, 0)
        self._index = (plugins, devices)

    def _find(self, msg):
        name = _norm(msg.get("name", ""))
        if not name:
            return None
        if self._index is None:
            self._build_index()
        plugins, devices = self._index
        pool = devices if msg.get("kind") == "device" else plugins
        hits = pool.get(name) or []
        if not hits:
            # Installed since the list was made: look again once.
            self._build_index()
            plugins, devices = self._index
            pool = devices if msg.get("kind") == "device" else plugins
            hits = pool.get(name) or []
        if not hits:
            return None
        # Audio Units first, then VST3, then VST, the way the app lists them.
        def rank(item):
            uri = (getattr(item, "uri", "") or "").lower()
            if "audiounit" in uri or "aupluginid" in uri:
                return 0
            if "vst3" in uri:
                return 1
            return 2
        return sorted(hits, key=rank)[0]

    def _load(self, msg):
        item = self._find(msg)
        if item is None:
            if msg.get("kind") == "device":
                return {"ok": False, "error": "%s is not in this version of Live." % msg.get("name", "That device")}
            return {"ok": False, "error": "%s is not in Live yet. In Live's Settings, Plug-Ins, turn on Use Audio Units v2 and let Live scan." % msg.get("name", "That plugin")}
        song = self.song()
        Live.Application.get_application().browser.load_item(item)
        return {"ok": True, "track": song.view.selected_track.name}

    def _track(self):
        track = self.song().view.selected_track
        devices = []
        for d in track.devices:
            devices.append({"name": d.name, "on": bool(d.parameters[0].value) if len(d.parameters) else True,
                            "kind": d.class_name})
        return {"ok": True, "track": track.name, "devices": devices}


def create_instance(c_instance):
    return AGPlugFinder(c_instance)
"""#
}
