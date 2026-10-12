#!/usr/bin/python3
# OpenThinRDP sign-in screen: full screen, the background of the site, a card with logo, user, password and
# Sign in in the middle; information and settings small in the top right corner, power (shut down, restart) in the
# bottom right one, the web button in the bottom left one. Started by kiosk.sh, which handles what follows.
# Exit codes (as the yad form it replaces): 10 = sign in ("user|password" on stdout), 3 = settings,
# 4 = diagnostics, 5 = shut down, 6 = restart, 7 = web button. "--class=OtrLogin" stays on the command line:
# kiosk.sh closes the screen with pkill -f -- '--class=OtrLogin'.
import argparse, locale, math, sys, time
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib

ap = argparse.ArgumentParser()
for a in ('class', 'title', 'heading', 'info', 'note', 'user', 'logo', 'splash', 'top', 'bottom', 'web',
          't-user', 't-password', 't-signin', 't-shutdown', 't-restart', 't-settings', 't-diag', 't-power',
          'open-power'):     # open-power: tests only, the power menu open (for a screenshot)
    ap.add_argument('--' + a, default='')
A = ap.parse_args()
try:
    locale.setlocale(locale.LC_ALL, "")      # day and month in the language of the system
except locale.Error:
    pass

def rgb(h, default):
    c = Gdk.RGBA()
    return c if c.parse(h or default) else (c.parse(default) and c)

CSS = b"""
.card { background: #ffffff; border-radius: 16px; padding: 30px 34px 26px 34px; }
.heading { color: #1f2937; font-size: 17px; font-weight: bold; }
.card entry { min-height: 40px; font-size: 15px; border-radius: 8px; border: 1px solid #cbd5e1; background: #f8fafc;
              color: #111827; padding: 0 10px; box-shadow: none; }
.card entry:focus { border-color: #2563eb; background: #ffffff; }
.signin { background: #2563eb; color: #ffffff; font-size: 15px; font-weight: bold; min-height: 42px; border-radius: 8px;
          border: none; box-shadow: none; background-image: none; text-shadow: none; }
.signin:hover { background: #1d4ed8; }
.note { color: #64748b; font-size: 12px; }
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
"""

# icons drawn here: the image has no icon theme
def icon(kind, size=22):
    d = Gtk.DrawingArea(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER); d.set_size_request(size, size)
    def draw(w, cr):
        s = size; cr.set_source_rgba(1, 1, 1, 0.92); cr.set_line_width(2.0); cr.set_line_cap(1)
        c = s / 2
        if kind == 'power':
            cr.arc(c, c + 1, s * 0.36, -math.pi / 2 + 0.75, 3 * math.pi / 2 - 0.75); cr.stroke()
            cr.move_to(c, 2); cr.line_to(c, c + 1); cr.stroke()
        elif kind == 'info':
            cr.arc(c, c, s * 0.42, 0, 2 * math.pi); cr.stroke()
            cr.arc(c, s * 0.30, 1.4, 0, 2 * math.pi); cr.fill()
            cr.move_to(c, s * 0.44); cr.line_to(c, s * 0.74); cr.stroke()
        elif kind == 'gear':
            for i in range(8):
                a = i * math.pi / 4
                cr.save(); cr.translate(c, c); cr.rotate(a); cr.rectangle(-2, -s * 0.47, 4, s * 0.2); cr.fill(); cr.restore()
            cr.arc(c, c, s * 0.30, 0, 2 * math.pi); cr.stroke()
            cr.arc(c, c, s * 0.11, 0, 2 * math.pi); cr.stroke()
    d.connect('draw', draw)
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

win = Gtk.Window(title=A.title or 'Remote desktop')
win.set_wmclass('OtrLogin', 'OtrLogin')
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

# middle: background picture of the site above the card
mid = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=26, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
sp = picture(A.splash, SW * 0.42, SH * 0.26) if A.splash else None
if sp: mid.pack_start(sp, False, False, 0)
card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12); card.get_style_context().add_class('card')
card.set_size_request(min(400, SW - 40), -1)
# the logo in the card only when the background picture is not shown above it: the same mark twice looks odd
lg = picture(A.logo, 240, 90) if A.logo and not sp else None
if lg: lg.set_margin_bottom(4); card.pack_start(lg, False, False, 0)
hd = Gtk.Label(label=A.heading, xalign=0.5); hd.get_style_context().add_class('heading'); hd.set_line_wrap(True)
card.pack_start(hd, False, False, 4)
eu = Gtk.Entry(placeholder_text=A.t_user or 'User'); eu.set_text(A.user)
ep = Gtk.Entry(placeholder_text=A.t_password or 'Password', visibility=False); ep.set_input_purpose(Gtk.InputPurpose.PASSWORD)
card.pack_start(eu, False, False, 0); card.pack_start(ep, False, False, 0)
bs = Gtk.Button(label=A.t_signin or 'Sign in'); bs.get_style_context().add_class('signin'); bs.set_margin_top(6)
card.pack_start(bs, False, False, 0)
if A.note:
    nt = Gtk.Label(label=A.note, xalign=0.5); nt.set_line_wrap(True); nt.set_max_width_chars(46)
    nt.get_style_context().add_class('note'); card.pack_start(nt, False, False, 2)
mid.pack_start(card, False, False, 0)
ov.add_overlay(mid)

def sign_in(*_):
    if ep.get_text():
        leave(10, eu.get_text().strip() + "|" + ep.get_text() + "|")   # trailing | as the yad form: kiosk.sh strips it
    else:
        ep.grab_focus()
bs.connect('clicked', sign_in); ep.connect('activate', sign_in); eu.connect('activate', lambda *_: ep.grab_focus())

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
    clk.set_text(time.strftime('%H:%M')); dt.set_text(time.strftime('%A %d %B').capitalize()); return True
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
for label, c in ((A.t_restart or 'Restart', 6), (A.t_shutdown or 'Shut down', 5)):
    b = Gtk.Button(label=label, xalign=0); b.connect('clicked', lambda _b, c=c: leave(c)); pb.pack_start(b, False, False, 0)
pb.show_all(); pop.add(pb)
pw.connect('clicked', lambda *_: pop.popup())
br = Gtk.Box(halign=Gtk.Align.END, valign=Gtk.Align.END, margin=22); br.pack_start(pw, False, False, 0); ov.add_overlay(br)

win.connect('delete-event', lambda *_: True)        # only the buttons close it
win.show_all()
(ep if A.user else eu).grab_focus(); eu.select_region(0, 0)
if A.open_power: GLib.timeout_add(300, lambda: pop.popup() and False)
Gtk.main()
sys.exit(code)
