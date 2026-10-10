# automatic login on tty1 starts X; the splash stays on screen until the kiosk draws its background
if [ -z "$DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then exec startx -- -background none >/tmp/startx.log 2>&1; fi
