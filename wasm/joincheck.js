// joins a Drakon game hosted by the game itself (Host a game...) through drakonnet.js, the
// way the web version does, and checks it: a wrong password is refused; the right one gets
// in and receives the host's setup; chat goes both ways. Used by joincheck.html (in a
// browser) and joincheck.mjs (in Node). Start the host first: love . --run tools/hostcheck.lua
(function (root) {
  "use strict";
  var V = "drakon-ws-1";

  function b64(s) {
    if (typeof btoa === "function") return btoa(unescape(encodeURIComponent(s)));
    return Buffer.from(s, "utf8").toString("base64");
  }
  function unb64(s) {
    if (typeof atob === "function") return decodeURIComponent(escape(atob(s)));
    return Buffer.from(s, "base64").toString("utf8");
  }
  // a message as the game's serial.lua writes it: { t = "chat", text = ... }
  function chat(text) {
    return "drakon1:{;s1:ts4:chats4:texts" + text.length + ":" + text + "}";
  }

  root.joinCheck = async function (url, password, log) {
    var N = root.DrakonNet, passed = 0, failed = 0, pending = {};
    function check(name, cond, detail) {
      if (cond) { passed++; log("ok    " + name); }
      else { failed++; log("FAIL  " + name + (detail !== undefined ? "  (" + detail + ")" : "")); }
    }
    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
    async function waitLine(id, re, ms) {
      var end = Date.now() + (ms || 4000);
      pending[id] = pending[id] || [];
      while (Date.now() < end) {
        var out = N.poll(id);
        if (out !== "") pending[id].push.apply(pending[id], out.split("\n"));
        while (pending[id].length) { var l = pending[id].shift(); if (re.test(l)) return l; }
        await sleep(20);
      }
      return null;
    }

    var wrong = N.open(url);
    N.send(wrong, "join " + V + " " + password + "x");
    var refused = await waitLine(wrong, /^m error|^c /);
    check("a wrong password is refused", refused === "m error Wrong password", refused);

    var me = N.open(url);
    N.send(me, "join " + V + " " + password);
    var joined = await waitLine(me, /^m joined |^m error|^c /);
    check("joins " + url + " with the password", joined && /^m joined \d+$/.test(joined), joined);
    // the game's hello, as session.lua's client sends it
    N.send(me, "send " + b64('drakon1:{;s1:ts5:hellos8:protocoln1;s4:names11:Web Browser}'));
    var lobby = null;
    for (var i = 0; i < 10 && !lobby; i++) {
      var line = await waitLine(me, /^m data /);
      if (!line) break;
      var msg = unb64(line.slice(7));
      if (msg.indexOf("s1:ts5:lobby") >= 0) lobby = msg;
    }
    check("receives the host's setup", lobby && lobby.indexOf("Web Browser") >= 0, lobby && lobby.slice(0, 60));
    N.send(me, "send " + b64(chat("hello from the web")));
    var reply = null;
    for (var j = 0; j < 10 && !reply; j++) {
      var l2 = await waitLine(me, /^m data /);
      if (!l2) break;
      var m2 = unb64(l2.slice(7));
      if (m2.indexOf("hello back") >= 0) reply = m2;
    }
    check("chat goes both ways", reply !== null);
    N.close(me);
    log(passed + " passed, " + failed + " failed");
    return failed === 0;
  };
})(typeof window !== "undefined" ? window : globalThis);
