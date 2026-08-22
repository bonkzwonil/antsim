;;;; tui/status.lisp — the line across the top (§5.6).
;;;;
;;;; The same numbers the window puts in its title bar and its counter
;;;; strip, in the same order and with the same names.  Two views of one
;;;; world that report different figures are worse than one view, because
;;;; then neither can be trusted; so this is deliberately a transcription
;;;; of LIVE-TITLE's field list rather than a fresh opinion about what
;;;; matters.
;;;;
;;;; A pure function returning a string, which is what makes it testable
;;;; and is also the thing the GL HUD cannot do — there the fields are
;;;; built and drawn in one pass of HUD-TEXT calls, so there is no
;;;; composed line to reuse.

(in-package #:antsim)

(defun tui-truncate (string cols)
  "STRING cut to COLS, with an ellipsis when something was lost."
  (declare (type string string) (type fixnum cols))
  (cond ((<= cols 0) "")
        ((<= (length string) cols) string)
        ((<= cols 1) (subseq string 0 cols))
        (t (concatenate 'string (subseq string 0 (1- cols)) "…"))))

(defun tui-speed-string (speed)
  "The speed multiplier, without the noise.

~G was the obvious directive and prints `1.0    x` — it pads to a field
width, and the padding lands between the number and its unit.  The speeds
this can hold are the powers of two between 1/32 and 4096, so an integer
prints as an integer and everything else gets just enough decimals to
tell 0.5 from 0.25."
  (let ((speed (float speed 1.0f0)))
    (if (= speed (fround speed))
        (format nil "~dx" (round speed))
        ;; Trim the zeros off the number, then add the unit.  Trimming
        ;; the formatted "0.50000x" would trim nothing at all, the last
        ;; character being the x.
        (format nil "~ax" (string-right-trim "0" (format nil "~,5f" speed))))))

(defun tui-status-fields (w &key (colony 0) (speed 1.0f0) paused fps)
  "The status line as a list of strings, most important first.

A list rather than a string because the terminal's width is not known
here and is not constant anywhere — the line has to be able to lose its
tail, and losing it in a defined order beats letting FORMAT decide."
  (declare (type world w) (type fixnum colony))
  (let* ((colonies (world-colonies w))
         (c (nth (min colony (max 0 (1- (length colonies)))) colonies)))
    (append
     (list (format nil "t ~,1fs" (world-seconds w)))
     ;; The colony's name only when there is more than one of them.  In a
     ;; single-colony world it is a constant, and a constant on a status
     ;; line is a column of screen nobody reads twice.
     (when (and c (> (length colonies) 1))
       (list (format nil "~a" (colony-name c))))
     ;; Rounded to integers rather than printed with ~,0F, which leaves a
     ;; trailing point — "stock 577." reads as a number that got cut off.
     (when c
       (list (format nil "~d ants" (colony-population c))
             (format nil "stock ~d" (round (colony-stock c)))
             (format nil "trail ~d" (round (field-total (colony-field c))))))
     (list (format nil "~a~:[~; PAUSED~]" (tui-speed-string speed) paused))
     (when fps (list (format nil "~d fps" (round fps)))))))

(defun tui-status (w &key (colony 0) (speed 1.0f0) paused fps (cols 80))
  "The status line, fitted to COLS.

Fields are dropped from the right until the line fits, and only then is
what remains truncated.  Wrapping would be the other option and is much
worse: a wrapped status line pushes the world down by a row, and the
world pane was sized on the assumption that it did not."
  (declare (type world w) (type fixnum cols))
  (let ((fields (tui-status-fields w :colony colony :speed speed
                                     :paused paused :fps fps)))
    (loop while (and (cdr fields)
                     (> (length (format nil "~{~a~^ · ~}" fields)) cols))
          do (setf fields (butlast fields)))
    (tui-truncate (format nil "~{~a~^ · ~}" fields) cols)))

(defparameter *tui-keys*
  '(("arrows/hjkl" "pan")
    ("HJKL"        "pan a page")
    ("+ -"         "speed")
    ("space"       "pause")
    ("."           "single step")
    ("f"           "fit the arena")
    ("z Z"         "zoom in / out")
    ("t"           "next colony")
    ("a"           "ascii / unicode")
    ("c"           "colour on / off")
    ("?"           "this list")
    ("q"           "quit"))
  "The legend, as data rather than as a run of writes — the same choice
*LIVE-KEYS* makes in the window, and for the same reason: a legend that
is a list can be printed by the help overlay, checked by a test, and
pasted into the docs without three copies of it drifting apart.")

(defun tui-help-lines ()
  "The key legend as printable lines."
  (let ((w (reduce #'max *tui-keys* :key (lambda (k) (length (first k))))))
    (mapcar (lambda (k)
              (format nil "~va  ~a" w (first k) (second k)))
            *tui-keys*)))
