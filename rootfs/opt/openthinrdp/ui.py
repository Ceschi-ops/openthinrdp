#!/usr/bin/python3
# OpenThinRDP screens for the user, all on the background of the site (gradient BG_TOP/BG_BOTTOM, the background
# picture above a white card). Started by kiosk.sh (and schedule.sh, browser.sh), which handle what follows.
#
#   ui.py login ...      sign-in screen: card with user, password, Sign in; clock and date top left, information and
#                        settings top right, power (restart, shut down) bottom right, web button and device bottom left.
#                        Exit: 10 = sign in ("user|password|" on stdout), 3 = settings, 4 = diagnostics, 5 = shut
#                        down, 6 = restart, 7 = web button. "--class=OtrLogin" stays on the command line: kiosk.sh
#                        closes it with pkill -f -- '--class=OtrLogin'.
#   ui.py message ...    a message: icon, heading, text, buttons (--button LABEL:CODE, in this order; --primary CODE
#                        is drawn as the main one, --default CODE has the focus, so Enter presses it).
#                        --timeout N: closes after N seconds with code 70 (a bar shows the time left).
#                        --progress: reads the yad progress protocol on stdin (a number = percent, "# text" = text)
#                        and ends with code 0 at the end of the input.
#                        --update: progress of the software update that is installing; ends when it is over.
#   ui.py toast ...      small notice in the top right corner with the progress of the software update; ends with it.
#                        --while-file PATH: a plain notice (no bar, warning icon) that stays while PATH exists
#                        (remote-screen.sh: "Remote assistance active").
# The admin dialogs (settings, diagnostics, PIN) stay yad windows.
import argparse, locale, math, os, subprocess, sys, time
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib

MODE = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 'login'
ap = argparse.ArgumentParser()
for a in ('class', 'title', 'heading', 'text', 'small', 'info', 'note', 'user', 'logo', 'splash', 'top', 'bottom',
          'web', 'icon', 'timeout', 'primary', 'default', 'lang',
          't-user', 't-password', 't-signin', 't-shutdown', 't-restart', 't-settings', 't-diag', 't-power',
          'open-power'):     # open-power: tests only, the power menu open (for a screenshot)
    ap.add_argument('--' + a, default='')
ap.add_argument('--button', action='append', default=[])
ap.add_argument('--progress', action='store_true')
ap.add_argument('--update', action='store_true')
ap.add_argument('--while-file', default='')
A = ap.parse_args(sys.argv[2:] if MODE != 'login' or (len(sys.argv) > 1 and sys.argv[1] == 'login') else sys.argv[1:])
try:
    locale.setlocale(locale.LC_ALL, "")      # day and month in the language of the system
except locale.Error:
    pass

PROGRESS_FILE = '/run/openthinrdp-update-progress'   # "percent version", written by auto-update.sh and install.sh
ACCENT = '#2563eb'

def rgb(h, default):
    c = Gdk.RGBA()
    return c if c.parse(h or default) else (c.parse(default) and c)

CSS = b"""
.card { background: #ffffff; border-radius: 16px; padding: 30px 34px 26px 34px; }
.heading { color: #1f2937; font-size: 17px; font-weight: bold; }
.text { color: #374151; font-size: 14px; }
.small, .note { color: #64748b; font-size: 12px; }
.card entry { min-height: 40px; font-size: 15px; border-radius: 8px; border: 1px solid #cbd5e1; background: #f8fafc;
              color: #111827; padding: 0 10px; box-shadow: none; }
.card entry:focus { border-color: #2563eb; background: #ffffff; }
.signin, .primary { background: #2563eb; color: #ffffff; font-size: 15px; font-weight: bold; min-height: 42px;
          border-radius: 8px; border: none; box-shadow: none; background-image: none; text-shadow: none; padding: 0 18px; }
.signin:hover, .primary:hover { background: #1d4ed8; }
.secondary { background: #eef2f7; color: #1f2937; font-size: 15px; min-height: 42px; border-radius: 8px; border: none;
             box-shadow: none; background-image: none; text-shadow: none; padding: 0 18px; }
.secondary:hover { background: #e2e8f0; }
.primary:focus, .secondary:focus { outline-color: #93c5fd; }
progressbar trough { min-height: 8px; border-radius: 4px; background: #e5e7eb; border: none; }
progressbar progress { min-height: 8px; border-radius: 4px; background: #2563eb; border: none; }
.corner { background: rgba(255,255,255,0.10); border-radius: 22px; border: none; box-shadow: none; background-image: none;
          min-width: 44px; min-height: 44px; padding: 0; }
.corner:hover { background: rgba(255,255,255,0.22); }
.webbtn { background: rgba(255,255,255,0.10); color: #ffffff; border-radius: 22px; border: none; box-shadow: none;
          background-image: none; min-height: 44px; padding: 0 18px; font-size: 14px; text-shadow: none; }
.webbtn:hover { background: rgba(255,255,255,0.22); }
.clock { color: #ffffff; font-size: 34px; font-weight: 300; }
.date, .device { color: rgba(255,255,255,0.75); font-size: 13px; }
popover { background: #ffffff; border-radius: 10px; }
popover button { background: transparent; border: none; box-shadow: none; background-image: none; color: #111827;
                 font-size: 14px; min-height: 38px; padding: 0 18px; }
popover button:hover { background: #eef2f7; }
.toast { background: #ffffff; border-radius: 12px; padding: 14px 18px; }
"""

# icons drawn here: the image has no icon theme. White on the background, coloured in a card.
COLORS = {'info': (0.15, 0.39, 0.92), 'ok': (0.09, 0.64, 0.29), 'warn': (0.85, 0.47, 0.02),
          'error': (0.86, 0.15, 0.15), 'power': (0.15, 0.39, 0.92), 'busy': (0.15, 0.39, 0.92),
          'update': (0.15, 0.39, 0.92)}

def icon(kind, size=22, color=(1, 1, 1), alpha=0.92):
    d = Gtk.DrawingArea(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER); d.set_size_request(size, size)
    state = {'a': 0.0}
    def draw(w, cr):
        s = size; c = s / 2; r, g, b = color
        cr.set_source_rgba(r, g, b, alpha); cr.set_line_width(max(2.0, s / 11)); cr.set_line_cap(1)
        if kind == 'power':
            cr.arc(c, c + s * 0.04, s * 0.36, -math.pi / 2 + 0.75, 3 * math.pi / 2 - 0.75); cr.stroke()
            cr.move_to(c, s * 0.09); cr.line_to(c, c + s * 0.04); cr.stroke()
        elif kind in ('info', 'error', 'warn'):
            cr.arc(c, c, s * 0.42, 0, 2 * math.pi); cr.stroke()
            if kind == 'info':
                cr.arc(c, s * 0.30, s * 0.06, 0, 2 * math.pi); cr.fill()
                cr.move_to(c, s * 0.44); cr.line_to(c, s * 0.74); cr.stroke()
            else:
                cr.move_to(c, s * 0.26); cr.line_to(c, s * 0.58); cr.stroke()
                cr.arc(c, s * 0.72, s * 0.06, 0, 2 * math.pi); cr.fill()
        elif kind == 'ok':
            cr.arc(c, c, s * 0.42, 0, 2 * math.pi); cr.stroke()
            cr.move_to(s * 0.30, s * 0.52); cr.line_to(s * 0.45, s * 0.66); cr.line_to(s * 0.71, s * 0.37); cr.stroke()
        elif kind in ('busy', 'update'):
            cr.set_source_rgba(r, g, b, 0.18); cr.arc(c, c, s * 0.40, 0, 2 * math.pi); cr.stroke()
            cr.set_source_rgba(r, g, b, alpha); cr.arc(c, c, s * 0.40, state['a'], state['a'] + 1.6); cr.stroke()
        elif kind == 'gear':
            for i in range(8):
                cr.save(); cr.translate(c, c); cr.rotate(i * math.pi / 4); cr.rectangle(-2, -s * 0.47, 4, s * 0.2)
                cr.fill(); cr.restore()
            cr.arc(c, c, s * 0.30, 0, 2 * math.pi); cr.stroke()
            cr.arc(c, c, s * 0.11, 0, 2 * math.pi); cr.stroke()
    d.connect('draw', draw)
    if kind in ('busy', 'update'):
        def spin():
            state['a'] = (state['a'] + 0.25) % (2 * math.pi); d.queue_draw(); return True
        GLib.timeout_add(50, spin)
    return d

def picture(path, maxw, maxh):
    try:
        pb = GdkPixbuf.Pixbuf.new_from_file(path)
    except Exception:
        return None
    k = min(1.0, maxw / pb.get_width(), maxh / pb.get_height())
    if k < 1.0:
        pb = pb.scale_simple(max(1, int(pb.get_width() * k)), max(1, int(pb.get_height() * k)), GdkPixbuf.InterpType.BILINEAR)
    return Gtk.Image.new_from_pixbuf(pb)

def label(text, cls, wrap=True, xalign=0.5, chars=52):
    l = Gtk.Label(label=text, xalign=xalign); l.get_style_context().add_class(cls)
    if wrap:
        l.set_line_wrap(True); l.set_max_width_chars(chars); l.set_justify(Gtk.Justification.CENTER)
    return l

# progress of the software update: (percent, version), or None when no update is installing
def update_progress():
    try:
        with open(PROGRESS_FILE) as f:
            p = f.read().split()
        return (max(0, min(100, int(p[0]))), p[1] if len(p) > 1 else '')
    except (OSError, ValueError, IndexError):
        return None

def update_running():
    if update_progress() is not None:
        return True
    return subprocess.run(['systemctl', 'is-active', '-q', 'openthinrdp-update.service']).returncode == 0

code = 1
def leave(c, out=None):
    global code
    code = c
    if out is not None:
        print(out, flush=True)
    Gtk.main_quit()

prov = Gtk.CssProvider(); prov.load_from_data(CSS)
Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
scr = Gdk.Screen.get_default()
mon = scr.get_display().get_primary_monitor() or scr.get_display().get_monitor(0)
geo = mon.get_geometry(); SW, SH = geo.width, geo.height

# --- small notice in the corner (no background) ------------------------------------------------------------
if MODE == 'toast':
    win = Gtk.Window(type=Gtk.WindowType.POPUP)
    win.set_wmclass('OtrToast', 'OtrToast')
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14); box.get_style_context().add_class('toast')
    kind = 'warn' if A.while_file else 'update'
    box.pack_start(icon(kind, 28, COLORS[kind], 1.0), False, False, 0)
    col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    tl = label(A.text, 'text', wrap=True, xalign=0, chars=34); col.pack_start(tl, False, False, 0)
    bar = Gtk.ProgressBar(); bar.set_size_request(260, -1)
    if not A.while_file: col.pack_start(bar, False, False, 0)
    box.pack_start(col, True, True, 0); win.add(box)
    def poll():
        if A.while_file:
            if not os.path.exists(A.while_file): leave(0); return False
            return True
        p = update_progress()
        if p is None and not update_running():
            leave(0); return False
        if p:
            bar.set_fraction(p[0] / 100.0); tl.set_text(A.text.replace('%v', p[1]).replace('%p', str(p[0])))
        return True
    poll(); GLib.timeout_add(700, poll)
    win.show_all()
    w, h = win.get_size(); win.move(geo.x + SW - w - 24, geo.y + 24)
    Gtk.main(); sys.exit(code)

# --- full screen: background, the picture of the site, a card ------------------------------------------------
win = Gtk.Window(title=A.title or 'Remote desktop')
win.set_wmclass('OtrLogin' if MODE == 'login' else 'OtrScreen', 'OtrLogin' if MODE == 'login' else 'OtrScreen')
win.set_decorated(False); win.move(geo.x, geo.y); win.set_default_size(SW, SH); win.fullscreen()
top, bottom = rgb(A.top, '#1b2733'), rgb(A.bottom, '#000000')
ov = Gtk.Overlay(); win.add(ov)
bg = Gtk.DrawingArea()
def draw_bg(w, cr):
    import cairo
    h = w.get_allocated_height(); g = cairo.LinearGradient(0, 0, 0, h)
    g.add_color_stop_rgb(0, top.red, top.green, top.blue); g.add_color_stop_rgb(1, bottom.red, bottom.green, bottom.blue)
    cr.set_source(g); cr.paint()
bg.connect('draw', draw_bg); ov.add(bg)

mid = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=26, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
sp = picture(A.splash, SW * 0.42, SH * 0.26) if A.splash else None
if sp: mid.pack_start(sp, False, False, 0)
card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12); card.get_style_context().add_class('card')
mid.pack_start(card, False, False, 0)
ov.add_overlay(mid)
win.connect('delete-event', lambda *_: True)        # only the buttons close it

if MODE == 'message':
    card.set_size_request(min(460, SW - 40), -1)
    if A.icon:
        ic = icon(A.icon, 46, COLORS.get(A.icon, COLORS['info']), 1.0); ic.set_margin_bottom(2); card.pack_start(ic, False, False, 0)
    if A.heading: card.pack_start(label(A.heading, 'heading'), False, False, 2)
    tx = label(A.text.replace('\\n', '\n'), 'text'); card.pack_start(tx, False, False, 0)
    bar = None
    if A.progress or A.update or A.timeout:
        bar = Gtk.ProgressBar(); bar.set_margin_top(6); card.pack_start(bar, False, False, 0)
    if A.small: card.pack_start(label(A.small.replace('\\n', '\n'), 'small'), False, False, 2)
    buttons = {}
    if A.button:
        row = Gtk.Box(spacing=10, halign=Gtk.Align.CENTER); row.set_margin_top(8)
        for b in A.button:
            text, _, c = b.rpartition(':')
            bt = Gtk.Button(label=text); bt.get_style_context().add_class('primary' if c == A.primary else 'secondary')
            bt.connect('clicked', lambda _b, c=int(c): leave(c)); row.pack_start(bt, False, False, 0); buttons[c] = bt
        card.pack_start(row, False, False, 0)
    if A.timeout:
        T = max(1, int(A.timeout)); t0 = time.time()
        def tick():
            left = T - (time.time() - t0)
            if left <= 0:
                leave(70); return False
            bar.set_fraction(left / T); return True
        tick(); GLib.timeout_add(100, tick)
    if A.progress:
        # the yad progress protocol on stdin: a number = percent, "# text" = text; 100 or end of input = done.
        # Between two steps the bar keeps moving slowly towards the next one, so it never looks stuck.
        st = {'target': 0.0, 'shown': 0.0}
        def creep():
            cap = min(st['target'] + 25.0, 95.0)
            if st['shown'] < cap:
                st['shown'] += max(0.05, (cap - st['shown']) * 0.012)
            bar.set_fraction(min(st['shown'], 100.0) / 100.0); return True
        GLib.timeout_add(100, creep)
        # Every line that has arrived, not one per wake-up: a percent and its text come together, and a buffered
        # second line would wait for the next write, so the text stayed one step behind (and stuck while waiting).
        pending = {'b': ''}
        def on_input(src, cond):
            try: data = os.read(sys.stdin.fileno(), 65536).decode('utf-8', 'replace')
            except BlockingIOError: return True
            if not data:
                leave(0); return False
            lines = (pending['b'] + data).split('\n'); pending['b'] = lines.pop()
            for line in (l.strip() for l in lines):
                if line.startswith('#'):
                    tx.set_text(line[1:].strip())
                    continue
                try: v = max(0.0, min(100.0, float(line)))
                except ValueError: continue
                st['target'] = v; st['shown'] = max(st['shown'], v)
                if v >= 100:
                    bar.set_fraction(1.0); GLib.timeout_add(250, lambda: leave(0) or False); return False
            return True
        GLib.io_add_watch(sys.stdin, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, on_input)
    if A.update:
        base = A.text.replace('\\n', '\n')
        def poll():
            p = update_progress()
            if p is None and not update_running():
                leave(0); return False
            if p:
                bar.set_fraction(p[0] / 100.0); tx.set_text(base.replace('%v', p[1]).replace('%p', str(p[0])))
            return True
        poll(); GLib.timeout_add(700, poll)
    win.show_all()
    if A.default in buttons: buttons[A.default].grab_focus()
    elif buttons: list(buttons.values())[0].grab_focus()
    Gtk.main(); sys.exit(code)

# --- sign-in screen --------------------------------------------------------------------------------------------
card.set_size_request(min(400, SW - 40), -1)
# the logo in the card only when the background picture is not shown above it: the same mark twice looks odd
lg = picture(A.logo, 240, 90) if A.logo and not sp else None
if lg: lg.set_margin_bottom(4); card.pack_start(lg, False, False, 0)
card.pack_start(label(A.heading, 'heading'), False, False, 4)
eu = Gtk.Entry(placeholder_text=A.t_user or 'User'); eu.set_text(A.user)
ep = Gtk.Entry(placeholder_text=A.t_password or 'Password', visibility=False); ep.set_input_purpose(Gtk.InputPurpose.PASSWORD)
card.pack_start(eu, False, False, 0); card.pack_start(ep, False, False, 0)
bs = Gtk.Button(label=A.t_signin or 'Sign in'); bs.get_style_context().add_class('signin'); bs.set_margin_top(6)
card.pack_start(bs, False, False, 0)
if A.note: card.pack_start(label(A.note, 'note', chars=46), False, False, 2)

def sign_in(*_):
    if ep.get_text():
        leave(10, eu.get_text().strip() + "|" + ep.get_text() + "|")   # trailing | as the yad form: kiosk.sh strips it
    else:
        ep.grab_focus()
bs.connect('clicked', sign_in); ep.connect('activate', sign_in); eu.connect('activate', lambda *_: ep.grab_focus())

# day and month in the language of the kiosk (LANGUAGE), not of the system: a system installed in English with
# LANGUAGE=it would show "Monday 12 October"
DAYS = {'it': ('lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica')}
MONTHS = {'it': ('gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre',
                 'ottobre', 'novembre', 'dicembre')}
def today():
    t = time.localtime()
    if A.lang in DAYS:
        return f"{DAYS[A.lang][t.tm_wday].capitalize()} {t.tm_mday} {MONTHS[A.lang][t.tm_mon - 1]}"
    s = time.strftime('%A %d %B', t); return s[:1].upper() + s[1:]   # capitalize() would lower "October"

def corner_button(kind, tip, cb):
    b = Gtk.Button(); b.add(icon(kind)); b.set_tooltip_text(tip); b.get_style_context().add_class('corner')
    b.set_can_focus(False)
    if cb: b.connect("clicked", cb)
    return b

# top left: clock and date; top right: information and settings
tl = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, halign=Gtk.Align.START, valign=Gtk.Align.START, margin=26)
clk = Gtk.Label(xalign=0); clk.get_style_context().add_class('clock')
dt = Gtk.Label(xalign=0); dt.get_style_context().add_class('date')
tl.pack_start(clk, False, False, 0); tl.pack_start(dt, False, False, 0); ov.add_overlay(tl)
def tick():
    clk.set_text(time.strftime('%H:%M')); dt.set_text(today()); return True
tick(); GLib.timeout_add_seconds(10, tick)
tr = Gtk.Box(spacing=10, halign=Gtk.Align.END, valign=Gtk.Align.START, margin=22)
tr.pack_start(corner_button('info', A.t_diag or 'Diagnostics', lambda *_: leave(4)), False, False, 0)
tr.pack_start(corner_button('gear', A.t_settings or 'Settings', lambda *_: leave(3)), False, False, 0)
ov.add_overlay(tr)

# bottom left: web button and the name of the device; bottom right: power with its menu
bl = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, halign=Gtk.Align.START, valign=Gtk.Align.END, margin=24)
if A.web:
    wb = Gtk.Button(label=A.web); wb.get_style_context().add_class('webbtn'); wb.set_can_focus(False)
    wb.connect('clicked', lambda *_: leave(7)); wb.set_halign(Gtk.Align.START); bl.pack_start(wb, False, False, 0)
if A.info:
    di = Gtk.Label(label=A.info, xalign=0); di.get_style_context().add_class('device'); bl.pack_start(di, False, False, 0)
ov.add_overlay(bl)
pw = corner_button('power', A.t_power or 'Power', None)
pop = Gtk.Popover(); pop.set_relative_to(pw); pop.set_position(Gtk.PositionType.TOP)
pb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin=6)
for text, c in ((A.t_restart or 'Restart', 6), (A.t_shutdown or 'Shut down', 5)):
    b = Gtk.Button(label=text, xalign=0); b.connect('clicked', lambda _b, c=c: leave(c)); pb.pack_start(b, False, False, 0)
pb.show_all(); pop.add(pb)
pw.connect('clicked', lambda *_: pop.popup())
br = Gtk.Box(halign=Gtk.Align.END, valign=Gtk.Align.END, margin=22); br.pack_start(pw, False, False, 0); ov.add_overlay(br)

win.show_all()
(ep if A.user else eu).grab_focus(); eu.select_region(0, 0)
if A.open_power: GLib.timeout_add(300, lambda: pop.popup() and False)
Gtk.main()
sys.exit(code)
