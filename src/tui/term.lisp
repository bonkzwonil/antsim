;;;; tui/term.lisp — the only file here that touches the operating system.
;;;;
;;;; Raw mode, the window size, the resize signal, and turning a canvas
;;;; diff into bytes.  Everything else in antsim/tui is arithmetic over
;;;; arrays and can be run, and is tested, on a machine with no terminal
;;;; at all.  Keeping the impurity in one file is what buys that.
;;;;
;;;; It is also the seam.  Every system call in the terminal view is in
;;;; here, on sb-posix — which ships with SBCL, so the promise that this
;;;; system adds no external dependency holds, and nothing new has to be
;;;; bundled into a package.  If a portable terminal library from
;;;; Quicklisp is preferred later, or the view is wanted on an
;;;; implementation that is not SBCL, this file is the whole of the
;;;; change: the camera, the canvas, the renderer, the status line and
;;;; the key decoder never learn about it.
;;;;
;;;; The dist was surveyed before settling on sb-posix, and the answer was
;;;; that nothing there does this job without a foreign library:
;;;;
;;;;   cl-charms, croatoan, cl-ncurses   need libncurses
;;;;   termbox2, cl-termbox              need libtermbox
;;;;   trivial-raw-io                    raw character reads only — no
;;;;                                     window size, no SIGWINCH
;;;;   terminfo                          pure Lisp, but it parses
;;;;                                     capability strings, and we emit
;;;;                                     plain ANSI and need none
;;;;   terminal-size                     not in the dist
;;;;
;;;; So the choice is not "portable library or sb-posix" but "bundle a C
;;;; library or use the one already in the image".  What a dependency
;;;; would actually buy is implementations other than SBCL — and the rest
;;;; of antsim is SBCL-only anyway (sb-thread in the core, save-lisp-and-die
;;;; for the binary), so it would buy that for this file alone.
;;;;
;;;; POSIX only, and that is stated rather than papered over.  termios and
;;;; TIOCGWINSZ are Linux and BSD; the window ships on Windows and the
;;;; terminal view does not.

(in-package #:antsim)

;;; --- how big is it? ----------------------------------------------------
;;;
;;; The ioctl, and not $COLUMNS.  A shell sets COLUMNS for itself and does
;;; not export it, so a program that reads the environment gets NIL on
;;; every terminal in the world and falls back to whatever it guesses —
;;; which is how a program comes to believe every terminal is eighty by
;;; twenty-four.  Measured here: with a real pty on the other end, the
;;; variable is absent and the ioctl answers.

(sb-alien:define-alien-type nil
  (sb-alien:struct tui-winsize
                   (ws-row sb-alien:unsigned-short)
                   (ws-col sb-alien:unsigned-short)
                   (ws-xpixel sb-alien:unsigned-short)
                   (ws-ypixel sb-alien:unsigned-short)))

(defconstant +tiocgwinsz+
  #+(or linux) #x5413
  #-(or linux) #x40087468
  "TIOCGWINSZ.  Linux picked a small ordinal; the BSDs encode the
direction and the struct size into the number, hence the two.")

(defconstant +tui-sigwinch+
  (or (let ((s (find-symbol "SIGWINCH" "SB-UNIX")))
        (and s (boundp s) (symbol-value s)))
      28)
  "SIGWINCH.  Looked up rather than hard-coded, with the Linux value as
the fallback for an SBCL that does not name it.")

(defvar *tui-resized* nil
  "Set by the SIGWINCH handler, cleared by the loop.

The handler sets a flag and does nothing else, deliberately.  Resizing
means allocating two new canvases and re-fitting the camera, and doing
that inside a signal handler — on whatever stack was interrupted,
possibly in the middle of the allocator — is how a program acquires an
intermittent crash that nobody can reproduce and everybody blames on
something else.")

(defun tui-terminal-size (&optional (fd 1))
  "Values: rows, columns.  NIL if this is not a terminal.

Falls back to `stty size` if the ioctl is refused, which costs a process
but answers correctly under the handful of odd pty implementations that
do not implement the ioctl."
  (or (ignore-errors
       (sb-alien:with-alien ((ws (sb-alien:struct tui-winsize)))
         (sb-posix:ioctl fd +tiocgwinsz+ (sb-alien:addr ws))
         (let ((rows (sb-alien:slot ws 'ws-row))
               (cols (sb-alien:slot ws 'ws-col)))
           (when (and (plusp rows) (plusp cols))
             (return-from tui-terminal-size (values rows cols))))))
      (ignore-errors
       (let* ((out (with-output-to-string (s)
                     (sb-ext:run-program "/bin/sh" '("-c" "stty size </dev/tty")
                                         :output s :error nil :search nil)))
              (parts (with-input-from-string (in out)
                       (list (read in nil nil) (read in nil nil)))))
         (when (and (integerp (first parts)) (integerp (second parts))
                    (plusp (first parts)) (plusp (second parts)))
           (values (first parts) (second parts)))))))

(defun tui-tty-p (&optional (fd 1))
  "Is FD a terminal?

Asked with TCGETATTR, which fails with ENOTTY on anything that is not
one — sb-posix exports no isatty, and this is what isatty does anyway.

Deliberately *not* asked by requesting the size.  Those are two different
questions, and conflating them means a terminal whose ioctl is refused —
some ptys, some containers — is turned away as \"not a terminal\" when it
is one and merely could not say how big it was.  Size has three
fallbacks below; being a tty has none, so it must be asked directly."
  (and (ignore-errors (sb-posix:tcgetattr fd)) t))

;;; --- how big is it, without an ioctl ----------------------------------
;;;
;;; The terminal will say, if asked in its own language: park the cursor
;;; somewhere absurd, and ask where it actually ended up.  It cannot go
;;; past the last row and column, so where it lands *is* the size.
;;;
;;; Escape sequences alone, no ioctl and no subprocess — but note what
;;; this does not get us.  Raw mode is a kernel tty discipline, not
;;; anything the terminal emulator controls, and no escape sequence turns
;;; canonical mode or echo off; termios is not avoidable.  So this is a
;;; third fallback for the size, not a way to do without sb-posix.
;;;
;;; It also requires raw mode to already be on — the reply comes back as
;;; ordinary input, and in canonical mode it would sit in the line buffer
;;; until somebody pressed return.  Hence it is used from the loop and
;;; never from TUI-TTY-P.

(defun tui-parse-cursor-report (s)
  "Values: rows, columns, from an `ESC [ rows ; cols R` reply.  NIL if S
is not one — pure, so a test needs no terminal."
  (declare (type string s))
  (let* ((esc (position +tui-esc+ s))
         (r (and esc (position #\R s :start esc))))
    (when (and esc r (< (1+ esc) r) (char= #\[ (char s (1+ esc))))
      (let* ((body (subseq s (+ esc 2) r))
             (semi (position #\; body)))
        (when semi
          (let ((rows (ignore-errors (parse-integer body :end semi)))
                (cols (ignore-errors (parse-integer body :start (1+ semi)))))
            (when (and rows cols (plusp rows) (plusp cols))
              (values rows cols))))))))

(defun tui-size-by-report (&optional (out *standard-output*)
                                     (in *standard-input*)
                                     (timeout 0.25))
  "Values: rows, columns, asked of the terminal itself.  NIL if it did
not answer within TIMEOUT.

The cursor is saved and restored around it, so a terminal that answers is
left exactly as it was and one that does not is no worse off."
  (write-string (format nil "~c[s~c[999;999H~c[6n" +tui-esc+ +tui-esc+ +tui-esc+)
                out)
  (force-output out)
  (let ((buf (make-string-output-stream))
        (deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((c (read-char-no-hang in nil nil)))
        (cond (c (write-char c buf)
                 (when (char= c #\R) (return)))
              ((> (get-internal-real-time) deadline) (return))
              ;; Nothing yet, and time left.  A short sleep rather than a
              ;; spin: the reply crosses a pty and takes microseconds,
              ;; and burning a core waiting for it would be absurd.
              (t (sleep 0.005)))))
    (write-string (format nil "~c[u" +tui-esc+) out)
    (force-output out)
    (tui-parse-cursor-report (get-output-stream-string buf))))

(defun tui-size ()
  "The terminal's size as (ROWS . COLS), or NIL if it will not say.

Three ways to ask, cheapest first: the ioctl, then `stty size` down
/dev/tty, then the terminal itself in its own language.  The last needs
raw mode already on, which is why this is called from the loop and never
from TUI-TTY-P.

The pair is taken or rejected together.  Asking one source for a row
count and another for a column count would let a half-answer through, and
half a size is not a smaller error than none."
  (flet ((ask (fn)
           (multiple-value-bind (r c) (ignore-errors (funcall fn))
             (and (integerp r) (integerp c) (plusp r) (plusp c) (cons r c)))))
    (or (ask #'tui-terminal-size)
        (ask #'tui-size-by-report))))

;;; --- raw mode ----------------------------------------------------------

(defun tui-raw-on (&optional (fd 0))
  "Put the terminal into raw mode.  Returns the previous settings, which
the caller must hand back to TUI-RAW-OFF.

ICANON off so a keystroke arrives without waiting for a newline; ECHO off
so it is not printed into the middle of the picture; ISIG off so ^C
arrives as a byte and the loop can unwind and put the terminal back
rather than being killed with the alternate screen still up; IXON off so
^S does not silently freeze the display.

VMIN 0 with VTIME 0 is what makes a read non-blocking: read returns
whatever is there, immediately, including nothing.  Measured at five
polls in under a millisecond, which is why the loop needs no second
thread and no select."
  (let ((saved (sb-posix:tcgetattr fd))
        (tc (sb-posix:tcgetattr fd)))
    (setf (sb-posix:termios-lflag tc)
          (logandc2 (sb-posix:termios-lflag tc)
                    (logior sb-posix:icanon sb-posix:echo
                            sb-posix:isig sb-posix:iexten)))
    (setf (sb-posix:termios-iflag tc)
          (logandc2 (sb-posix:termios-iflag tc) sb-posix:ixon))
    (setf (aref (sb-posix:termios-cc tc) sb-posix:vmin) 0)
    (setf (aref (sb-posix:termios-cc tc) sb-posix:vtime) 0)
    (sb-posix:tcsetattr fd sb-posix:tcsanow tc)
    saved))

(defun tui-raw-off (saved &optional (fd 0))
  (when saved
    (ignore-errors (sb-posix:tcsetattr fd sb-posix:tcsanow saved))))

;;; --- escape sequences we send -----------------------------------------

(defparameter *tui-alt-screen-on*  (format nil "~c[?1049h" +tui-esc+))
(defparameter *tui-alt-screen-off* (format nil "~c[?1049l" +tui-esc+))
(defparameter *tui-cursor-hide*    (format nil "~c[?25l" +tui-esc+))
(defparameter *tui-cursor-show*    (format nil "~c[?25h" +tui-esc+))
(defparameter *tui-sgr-reset*      (format nil "~c[0m" +tui-esc+))
(defparameter *tui-clear*          (format nil "~c[2J~c[H" +tui-esc+ +tui-esc+))

(defun tui-emit-diff (stream runs)
  "Write the changed runs, and nothing else.

One cursor placement and at most one colour change per run — which is
the entire reason the canvas diff groups by colour as well as by
position.  A full repaint of a large terminal is twelve thousand cells a
frame and looks like it; this is typically a few dozen."
  (let ((fg -1))
    (dolist (run runs)
      (destructuring-bind (row col string colour) run
        ;; Terminals count from one, arrays from zero.
        (format stream "~c[~d;~dH" +tui-esc+ (1+ row) (1+ col))
        (unless (= fg colour)
          (setf fg colour)
          (if (= colour +tui-default+)
              (write-string *tui-sgr-reset* stream)
              (format stream "~c[~dm" +tui-esc+ colour)))
        (write-string string stream)))
    (unless (= fg -1)
      (write-string *tui-sgr-reset* stream))))

;;; --- input -------------------------------------------------------------

(defun tui-read-available (&optional (stream *standard-input*))
  "Everything the terminal has for us right now, as a string.  Empty when
it has nothing — VMIN 0 means the read does not wait."
  (let ((out (make-string-output-stream)))
    (loop for c = (read-char-no-hang stream nil nil)
          while c do (write-char c out))
    (get-output-stream-string out)))

;;; --- the session -------------------------------------------------------

(defmacro with-terminal ((&key (stream '*standard-output*)) &body body)
  "Run BODY with the terminal in raw mode on the alternate screen, and
put it back afterwards whatever happens.

The UNWIND-PROTECT is the point of the macro.  The one failure in this
whole feature that outlives the process is leaving the terminal in raw
mode with no echo and the alternate screen up: the user is then sitting
in a shell that appears to have stopped working, and `reset` is not
something everybody knows.  So it is restored on the normal exit, on an
error, and on the interrupt — and ISIG is off precisely so that the
interrupt comes through the key decoder and takes this path too."
  (let ((saved (gensym "SAVED")) (handler (gensym "HANDLER")))
    `(let ((,saved nil)
           (,handler nil))
       (declare (ignorable ,handler))
       (unwind-protect
            (progn
              (setf ,saved (tui-raw-on))
              (setf *tui-resized* nil)
              (ignore-errors
               (setf ,handler
                     (sb-sys:enable-interrupt
                      +tui-sigwinch+
                      (lambda (&rest ignore)
                        (declare (ignore ignore))
                        (setf *tui-resized* t)))))
              (write-string *tui-alt-screen-on* ,stream)
              (write-string *tui-cursor-hide* ,stream)
              (write-string *tui-clear* ,stream)
              (force-output ,stream)
              ,@body)
         (ignore-errors (write-string *tui-sgr-reset* ,stream))
         (ignore-errors (write-string *tui-cursor-show* ,stream))
         (ignore-errors (write-string *tui-alt-screen-off* ,stream))
         (ignore-errors (force-output ,stream))
         (tui-raw-off ,saved)))))
