// Drakon's network bridge for the web build (love.js): the game can't open sockets in a
// browser, so this owns real WebSockets and the game talks to it through love.js.eval
// (see src/webbridge.lua). Every call takes and returns plain text.
//
//   DrakonNet.open(url)      -> "<id>", or "0 <why>"
//   DrakonNet.send(id, text) -> ""     (held until the connection is open)
//   DrakonNet.poll(id)       -> what happened since last asked, one event per line:
//                               "o" opened, "m <text>" a message, "c <why>" closed
//   DrakonNet.close(id)      -> ""
//
// Load it in the page before player.js: <script src="drakonnet.js"></script>
(function () {
  "use strict";
  var conns = {};
  var nextId = 1;

  function oneLine(s) {
    return String(s).replace(/[\r\n]+/g, " ");
  }

  window.DrakonNet = {
    open: function (url) {
      var c = { queue: [], pending: [], closed: false };
      try {
        c.ws = new WebSocket(url);
      } catch (e) {
        return "0 " + oneLine(e && e.message ? e.message : e);
      }
      c.ws.onopen = function () {
        c.queue.push("o");
        for (var i = 0; i < c.pending.length; i++) c.ws.send(c.pending[i]);
        c.pending = [];
      };
      c.ws.onmessage = function (ev) {
        if (typeof ev.data === "string") c.queue.push("m " + oneLine(ev.data));
      };
      c.ws.onclose = function (ev) {
        if (c.closed) return;
        c.closed = true;
        var why = ev.reason || (ev.code === 1006 ? "Could not reach the host" : "The connection closed (" + ev.code + ")");
        c.queue.push("c " + oneLine(why));
      };
      var id = nextId++;
      conns[id] = c;
      return String(id);
    },

    send: function (id, text) {
      var c = conns[id];
      if (!c || c.closed) return "";
      if (c.ws.readyState === 1) c.ws.send(text);
      else if (c.ws.readyState === 0) c.pending.push(text);
      return "";
    },

    poll: function (id) {
      var c = conns[id];
      if (!c) return "";
      var out = c.queue.join("\n");
      c.queue = [];
      if (c.closed && out === "") delete conns[id];
      return out;
    },

    close: function (id) {
      var c = conns[id];
      if (!c) return "";
      c.closed = true;
      try { c.ws.close(1000); } catch (e) { /* already closing */ }
      delete conns[id];
      return "";
    },
  };
})();
