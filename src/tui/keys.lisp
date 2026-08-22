;;;; tui/keys.lisp — decoding what a terminal sends when a key goes down.
;;;;
;;;; An arrow key is not a character.  It arrives as `ESC [ A` — three
;;;; bytes — and the terminal is under no obligation to deliver all three
;;;; in one read.  Everything awkward about this file follows from those
;;;; two facts.
;;;;
;;;; The decoder is therefore a function from a buffer to (keys, what is
;;;; left over), and the loop keeps the leftovers and hands them back
;;;; next time.  A sequence split across two polls is then simply a
;;;; sequence that was incomplete once and complete the second time,
;;;; rather than a dropped key and a stray `[A` printed into the world.
;;;;
;;;; It is pure, and separate from tui/term.lisp for exactly that reason:
;;;; this is the fiddliest code in the terminal view and the part most
;;;; worth testing, and a test for it should not have to own a tty.

(in-package #:antsim)

(defconstant +tui-esc+ (code-char 27))

;;; --- the lone escape ---------------------------------------------------
;;;
;;; The classic ambiguity, and there is no way to resolve it inside the
;;; buffer: a buffer holding exactly `ESC` is either the escape key, or
;;; the first byte of an arrow key whose other two bytes have not arrived
;;; yet.  Nothing in the byte stream distinguishes them.
;;;
;;; So it is resolved in time instead.  The decoder leaves a trailing ESC
;;; in the leftovers and says nothing about it; the loop polls again, and
;;; if that poll brought nothing new it calls back with FLUSH true, which
;;; is the caller saying "no more is coming — decide".  One frame of
;;; latency on the escape key, and no misread arrows, which is the right
;;; way round.

(defun tui-csi-key (params final)
  "Map a CSI final byte and its numeric parameters to a key.

PARAMS is a list of integers: `ESC [ 1 ; 2 A` is (1 2) with final #\\A,
and the 2 is the modifier — 2 is shift, 3 alt, 5 control, in the xterm
encoding every terminal worth supporting follows."
  (let* ((mod (or (second params) 1))
         (shift (member mod '(2 4 6 8)))
         (base (case final
                 (#\A :up) (#\B :down) (#\C :right) (#\D :left)
                 (#\H :home) (#\F :end)
                 (#\~ (case (or (first params) 0)
                        (1 :home) (4 :end) (5 :page-up) (6 :page-down)
                        (t nil)))
                 (t nil))))
    (if (and shift (member base '(:up :down :left :right)))
        (ecase base
          (:up :shift-up) (:down :shift-down)
          (:left :shift-left) (:right :shift-right))
        base)))

(defun tui-decode-keys (buf &key flush)
  "Decode BUF into a list of keys.

Values: the keys, and the undecoded tail of BUF.  A key is a character
for anything that is one, or a keyword — :UP :DOWN :LEFT :RIGHT,
:SHIFT-UP and friends, :PAGE-UP, :PAGE-DOWN, :HOME, :END, :ESCAPE,
:CTRL-C — for anything that is not.

With FLUSH true a trailing lone ESC decodes as :ESCAPE instead of being
held back; see the note above."
  (declare (type string buf))
  (let ((keys '())
        (i 0)
        (n (length buf)))
    (flet ((done (from) (return-from tui-decode-keys
                          (values (nreverse keys) (subseq buf from)))))
      (loop while (< i n)
            do (let ((ch (char buf i)))
                 (cond
                   ;; --- an escape sequence, or the escape key ----------
                   ((char= ch +tui-esc+)
                    (cond
                      ;; Nothing after it yet.
                      ((>= (1+ i) n)
                       (if flush
                           (progn (push :escape keys) (incf i))
                           (done i)))
                      ;; CSI: ESC [ params final
                      ((char= (char buf (1+ i)) #\[)
                       (let ((j (+ i 2))
                             (params '())
                             (cur nil))
                         (loop while (and (< j n)
                                          (let ((c (char buf j)))
                                            (or (digit-char-p c) (char= c #\;))))
                               do (let ((c (char buf j)))
                                    (if (char= c #\;)
                                        (progn (push (or cur 0) params) (setf cur nil))
                                        (setf cur (+ (* 10 (or cur 0))
                                                     (digit-char-p c))))
                                    (incf j)))
                         (when cur (push cur params))
                         (if (>= j n)
                             ;; Truncated mid-sequence: keep it all and
                             ;; try again when more has arrived.
                             (done i)
                             (let ((key (tui-csi-key (nreverse params)
                                                     (char buf j))))
                               (when key (push key keys))
                               (setf i (1+ j))))))
                      ;; SS3: ESC O final — what many terminals send for
                      ;; the arrows when the keypad is in application
                      ;; mode.  Same finals, one byte shorter.
                      ((char= (char buf (1+ i)) #\O)
                       (if (>= (+ i 2) n)
                           (done i)
                           (let ((key (tui-csi-key '() (char buf (+ i 2)))))
                             (when key (push key keys))
                             (setf i (+ i 3)))))
                      ;; ESC followed by something else: the escape key,
                      ;; and then whatever that something is.
                      (t (push :escape keys) (incf i))))
                   ;; --- ^C ---------------------------------------------
                   ;; Arrives as a byte rather than as a signal, because
                   ;; raw mode clears ISIG.  Handled as a key so that the
                   ;; loop can unwind properly and put the terminal back;
                   ;; a process killed by SIGINT here would leave the
                   ;; user in a shell with no echo.
                   ((char= ch (code-char 3)) (push :ctrl-c keys) (incf i))
                   (t (push ch keys) (incf i)))))
      (values (nreverse keys) ""))))
