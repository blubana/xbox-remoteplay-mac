// 虛擬手把:把鍵盤/滑鼠轉成標準 Gamepad(Xbox 佈局),
// 覆寫 navigator.getGamepads(),真實手把仍會保留。F8 開關。
(() => {
  if (window.__vpad) return;
  const KEYS = {            // 鍵位 → 標準 Gamepad 按鈕索引
    Space:0, KeyC:1, KeyE:2, KeyQ:3, KeyZ:4, KeyX:5, ShiftLeft:6, KeyF:7,
    Tab:8, Enter:9, KeyV:10, KeyB:11,
    ArrowUp:12, ArrowDown:13, ArrowLeft:14, ArrowRight:15, Escape:16,
  };
  const STICK = { KeyW:[0,-1], KeyS:[0,1], KeyA:[-1,0], KeyD:[1,0] };  // 左搖桿
  const RSTICK = { KeyI:[0,-1], KeyK:[0,1], KeyJ:[-1,0], KeyL:[1,0] }; // 右搖桿(無滑鼠時)
  const st = { on: true, look: false, btn: new Array(17).fill(0), down: new Set(), mx: 0, my: 0, lt: 0, rt: 0, connected: false };
  const SENS = 0.045;

  const mk = (v) => ({ pressed: v > 0.5, touched: v > 0, value: v });
  function axis(map) {
    let x = 0, y = 0;
    for (const k of st.down) if (map[k]) { x += map[k][0]; y += map[k][1]; }
    const m = Math.hypot(x, y); if (m > 1) { x /= m; y /= m; }
    return [x, y];
  }
  function snapshot() {
    const [lx, ly] = axis(STICK), [kx, ky] = axis(RSTICK);
    const rx = Math.max(-1, Math.min(1, kx + st.mx)), ry = Math.max(-1, Math.min(1, ky + st.my));
    st.mx *= 0.6; st.my *= 0.6;                      // 滑鼠位移衰減 → 搖桿回中
    const b = st.btn.map((v) => v);
    for (const k of st.down) if (k in KEYS) b[KEYS[k]] = 1;
    b[6] = Math.max(b[6], st.lt); b[7] = Math.max(b[7], st.rt);
    return {
      id: 'Xbox 360 Controller (STANDARD GAMEPAD Vendor: 045e Product: 028e)',
      index: 0, connected: true, mapping: 'standard', timestamp: performance.now(),
      axes: [lx, ly, rx, ry], buttons: b.map(mk), vibrationActuator: null, hapticActuators: [],
    };
  }

  const real = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : () => [];
  navigator.getGamepads = function () {
    const r = Array.from(real() || []);
    if (!st.on) return r;
    let slot = r.findIndex((g) => !g);
    if (slot < 0) slot = r.length;
    const v = snapshot(); v.index = slot; r[slot] = v;
    if (!st.connected) {
      st.connected = true;
      const ev = new Event('gamepadconnected'); ev.gamepad = v; setTimeout(() => window.dispatchEvent(ev));
    }
    return r;
  };

  const handled = (e) => e.code in KEYS || e.code in STICK || e.code in RSTICK;
  const typing = (e) => /^(INPUT|TEXTAREA)$/.test(e.target.tagName) || e.target.isContentEditable;
  addEventListener('keydown', (e) => {
    if (e.code === 'F8') { st.on = !st.on; st.down.clear(); console.log('virtual pad', st.on); return; }
    if (!st.on || typing(e) || !handled(e)) return;
    st.down.add(e.code); e.preventDefault();
  }, true);
  addEventListener('keyup', (e) => { if (st.down.delete(e.code)) e.preventDefault(); }, true);
  addEventListener('blur', () => st.down.clear());
  addEventListener('mousedown', (e) => { if (!st.on) return;
    if (st.look && !document.pointerLockElement) { try { document.documentElement.requestPointerLock(); } catch (_) {} } if (e.button === 0) st.rt = 1; if (e.button === 2) st.lt = 1; }, true);
  addEventListener('mouseup', (e) => { if (e.button === 0) st.rt = 0; if (e.button === 2) st.lt = 0; }, true);
  addEventListener('mousemove', (e) => {
    if (!st.on || !document.pointerLockElement) return;   // 只在滑鼠鎖定時當作右搖桿
    st.mx += e.movementX * SENS; st.my += e.movementY * SENS;
  }, true);
  window.__vpad = st;
})();
