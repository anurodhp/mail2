#!/bin/sh
# Guest side of tools/qemu_shots.sh (copied to /var/root/mail2_shots.sh and run as root in the QEMU guest). Brings up
# the real desktop on Xvfb (gsdm's Xsession: Window Maker, Naples, Milan), starts Mail2 -- whose account points at
# GreenMail on the host (10.0.2.2) -- and takes screenshots (xwd) into /var/root/shots:
#   viewer        the three panes after the Inbox synced, with the dock badge
#   conversation  the top row (a conversation of three) opened
#   message       the second message selected (HTML shown as text)
#   search        a search for "quarterly"
#   draft         the draft from Drafts reopened, with its attachment, then sent
#   compose       a new message typed in, then sent with Shift-Cmd-D
#   sent          the viewer after sending
# GNUstep starts slowly under QEMU/TCG: every step waits for its window (x11_probe tree), then lets it draw.
T=/var/root/shots
X=/usr/X11/bin
GEOM=${GEOM:-1280x800}
WAIT=${WAIT:-600}
SETTLE=${SETTLE:-60}
export DISPLAY=:0 HOME=/var/root
# HTML_SHOT=1 (from /var/root/mail2_shots.env, written by qemu_shots.sh when Florence's WebKit is installed): only
# the HTML message, in WebKit, then stop
[ -f /var/root/mail2_shots.env ] && . /var/root/mail2_shots.env
mkdir -p $T

echo "== Xvfb $GEOM"
$X/Xvfb :0 -screen 0 ${GEOM}x24 -nolisten tcp > $T/xvfb.log 2>&1 &
i=0
until $X/x11_probe tree > /dev/null 2>&1; do
    sleep 2; i=$((i + 2))
    [ $i -ge 120 ] && { echo "Xvfb did not start"; cat $T/xvfb.log; echo "SHOTS DONE"; exit 1; }
done

wait_window() {
    i=0
    while [ $i -lt $WAIT ]; do
        $X/x11_probe tree 2>/dev/null | grep ' viewable' | grep -q "name=$1" && break
        sleep 5; i=$((i + 5))
    done
    echo "window '$1' after ${i}s"
    [ $i -lt $WAIT ]
}
geometry() { $X/x11_probe tree | grep ' viewable' | grep "name=$1" | head -1 | awk '{print $2}'; }
shot() { $X/xwd -root -out $T/$1.xwd; echo "shot $1 rc=$?"; }

echo "== desktop"
sh /etc/gsdm/Xsession > $T/xsession.log 2>&1 &
i=0
until ps -ax -o command | grep -q '^/Applications/Naples.app/Naples'; do
    sleep 5; i=$((i + 5))
    [ $i -ge 300 ] && { echo "Naples did not start"; break; }
done
sleep ${DESKTOP_SETTLE:-180}
export GNUSTEP_CONFIG_FILE=/etc/GNUstep/GNUstep.conf
[ -f /System/Library/Makefiles/GNUstep.sh ] && . /System/Library/Makefiles/GNUstep.sh

echo "== Mail2"
# PROFILE=1: where the main thread spends wall-clock time (iokit's sample_prof), written when Mail2 exits (SIGUSR1)
PROF=""
[ "${PROFILE:-0}" = 1 ] && [ -f /usr/local/lib/sample_prof.dylib ] && PROF="DYLD_INSERT_LIBRARIES=/usr/local/lib/sample_prof.dylib SAMPLE_PROF_WALL=1 SAMPLE_PROF_OUT=$T/prof.txt"
# crashdiag (iokit): a backtrace on a crash
[ -z "$PROF" ] && [ -f /usr/lib/crashdiag.dylib ] && PROF="DYLD_INSERT_LIBRARIES=/usr/lib/crashdiag.dylib"
env $PROF MAIL2_DEBUG=1 /Applications/Mail2.app/Mail2 > $T/mail2.log 2>&1 &
MP=$!
if wait_window 'Inbox'; then
    # until the list has filled and the bodies are in (the title counts unread)
    sleep $SETTLE
    g=$(geometry Inbox)
    echo "Mail2 window $g"
    w=${g%%x*}; r=${g#*x}; h=${r%%+*}; r=${r#*+}; x=${r%%+*}; y=${r#*+}
    shot viewer
    click() { $X/xinject move $1 $2 sleep 300 down $1 $2 sleep 300 up; }
    LX=$((x + 380))
    if [ "${HTML_SHOT:-0}" = 1 ]; then
        # the GitHub message (HTML), the fifth row: WebKit starts on this first HTML message
        click $LX $((y + 44 + 62 * 4 + 31))
        sleep ${HTML_WAIT:-300}
        shot html
        sleep 120
        shot html2
        $X/x11_probe tree | grep ' viewable' > $T/windows.log
        ps -ax -o pid,command | grep -E '[M]ail2|[W]PE'
        kill -USR1 $MP 2>/dev/null; sleep 10; kill $MP 2>/dev/null; sleep 2
        sync; sleep 2; sync
        echo "SHOTS DONE"
        exit 0
    fi
    # the top row: the lunch conversation (3 messages); selecting it opens it
    click $LX $((y + 44 + 31))
    sleep 40
    shot conversation
    # the second message in the list (rows are 62 high under the 44-high toolbar; the list starts after the sidebar)
    # pressed and released 0.3 s apart, as a hand does: a press and release with nothing between them can reach
    # GNUstep reversed on a window that is not yet the key window (it defers the press while activating)
    $X/xinject move $((x + 380)) $((y + 44 + 62 + 31)) sleep 300 down $((x + 380)) $((y + 44 + 62 + 31)) sleep 300 up
    sleep 40
    shot message
    sleep 30
    # search: Cmd-F, a word, Return
    $X/xinject key cmd+f sleep 1000 type "quarterly" key Return
    sleep 60
    shot search
    $X/xinject key cmd+a key BackSpace key Return
    sleep 20
    # Drafts (the sidebar: the account heading, Inbox, Drafts; rows 26 high), its message, Return opens it
    click $((x + 80)) $((y + 44 + 26 * 2 + 13))
    sleep 60
    click $LX $((y + 44 + 31))
    sleep 60
    $X/xinject key Return
    WAIT=300
    if wait_window 'Draft'; then
        sleep 40
        shot draft
        $X/xinject key shift+cmd+d
        sleep 60
    else
        shot nodraft
    fi
    # back to the Inbox
    click $((x + 80)) $((y + 44 + 26 + 13))
    sleep 30
    # New Message: Cmd-N (the menu item and the toolbar button share the action)
    $X/xinject key cmd+n
    WAIT=300
    if wait_window 'New'; then
        sleep 40
        # xinject types no "@" (it has no keysym by that name): Shift-2 on the US layout
        $X/xinject type "test2" key shift+2 type "localhost" key Tab key Tab key Tab type "Hello from QEMU" key Tab \
            type "Sent from Mail2 on Darwin, under QEMU." sleep 2000
        sleep 20
        shot compose
        $X/xinject key shift+cmd+d
        sleep 60
        shot sent
    else
        shot nocompose
    fi
else
    shot failed
fi
$X/x11_probe tree | grep ' viewable' > $T/windows.log
ps -ax -o pid,command | grep -E '[M]ail2|[N]aples'
kill -USR1 $MP 2>/dev/null; sleep 10; kill $MP 2>/dev/null; sleep 2
ls -l $T
sync; sleep 2; sync
echo "SHOTS DONE"
