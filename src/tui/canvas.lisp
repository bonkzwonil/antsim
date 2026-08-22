;;;; tui/canvas.lisp — a character grid, and the difference between two.
;;;;
;;;; The whole reason the terminal view can be tested on a machine with no
;;;; terminal.  A frame is *this*, not a stream of escape sequences: a
;;;; rectangle of characters and a rectangle of colours, built by pure
;;;; functions, which a test can index into and a REPL can print.  Only
;;;; tui/term.lisp turns one into bytes.
;;;;
;;;; Two of them are kept at all times, and the difference between them is
;;;; what actually goes down the wire.  Repainting a 200x60 terminal every
;;;; frame is twelve thousand cells, most of which did not change, and it
;;;; looks exactly like what it is — a tear rolling down the screen once a
;;;; frame.  Emitting only the runs that changed is both far less traffic
;;;; and, more to the point, flicker-free, because the cells nobody
;;;; touched are never rewritten at all.

(in-package #:antsim)

;;; A colour is an ANSI SGR foreground number — 30-37 and the bright
;;; 90-97 — stored raw so that writing one is a format of the number
;;; rather than a lookup, with 0 meaning "the terminal's own default".
;;; Sixteen colours rather than 256, because these are the ones every
;;; terminal in the world agrees about and the picture needs six.

(defconstant +tui-default+ 0)

(defstruct (tui-canvas (:conc-name tcv-) (:constructor %make-tui-canvas))
  (cols 0 :type fixnum)
  (rows 0 :type fixnum)
  (chars nil :type (or null (simple-array character (*))))
  (fg nil :type (or null u8v)))

(defun make-tui-canvas (cols rows)
  (let ((cols (max 0 cols)) (rows (max 0 rows)))
    (%make-tui-canvas
     :cols cols :rows rows
     :chars (make-array (* cols rows) :element-type 'character
                                      :initial-element #\Space)
     :fg (mku8 (* cols rows) +tui-default+))))

(declaim (inline tcv-index tcv-inside-p))
(defun tcv-inside-p (cv col row)
  (declare (type tui-canvas cv) (type fixnum col row))
  (and (>= col 0) (< col (tcv-cols cv)) (>= row 0) (< row (tcv-rows cv))))

(defun tcv-index (cv col row)
  (declare (type tui-canvas cv) (type fixnum col row))
  (+ col (* row (tcv-cols cv))))

(defun tui-clear! (cv &optional (char #\Space) (fg +tui-default+))
  (declare (type tui-canvas cv))
  (fill (tcv-chars cv) char)
  (fill (tcv-fg cv) fg)
  cv)

(defun tui-put! (cv col row char &optional (fg +tui-default+))
  "Write one cell.  Out-of-range is a no-op rather than an error: almost
everything drawn here is at a world position that may or may not be on
screen, and making every caller test that first would put the same three
lines in front of every draw loop in tui/draw.lisp."
  (declare (type tui-canvas cv) (type fixnum col row) (type character char))
  (when (tcv-inside-p cv col row)
    (let ((i (tcv-index cv col row)))
      (setf (aref (tcv-chars cv) i) char
            (aref (tcv-fg cv) i) fg)))
  cv)

(defun tui-at (cv col row)
  "Values: the character and the colour at a cell.  Space and the default
colour for anything off the grid."
  (declare (type tui-canvas cv) (type fixnum col row))
  (if (tcv-inside-p cv col row)
      (let ((i (tcv-index cv col row)))
        (values (aref (tcv-chars cv) i) (aref (tcv-fg cv) i)))
      (values #\Space +tui-default+)))

(defun tui-write! (cv col row string &optional (fg +tui-default+))
  "Write a string along a row, clipped at both ends.  Returns the column
one past the last cell written."
  (declare (type tui-canvas cv) (type fixnum col row) (type string string))
  (loop for i from 0 below (length string)
        do (tui-put! cv (+ col i) row (char string i) fg))
  (+ col (length string)))

(defun tui-canvas-string (cv)
  "The whole canvas as one string, rows separated by newlines and colour
thrown away.

This is what makes the renderer usable and testable without a terminal:
`(princ (tui-canvas-string (tui-frame w)))` in a REPL prints a colony."
  (declare (type tui-canvas cv))
  (with-output-to-string (out)
    (dotimes (row (tcv-rows cv))
      (let ((start (tcv-index cv 0 row)))
        ;; Trailing spaces are dropped.  A canvas is mostly empty and the
        ;; blanks carry nothing; keeping them makes every REPL print a
        ;; block of whitespace as wide as the terminal.
        (let ((end (tcv-cols cv)))
          (loop while (and (> end 0)
                           (char= #\Space (aref (tcv-chars cv) (+ start end -1))))
                do (decf end))
          (dotimes (col end)
            (write-char (aref (tcv-chars cv) (+ start col)) out))))
      (terpri out))))

(defun tui-same-size-p (a b)
  (and a b (= (tcv-cols a) (tcv-cols b)) (= (tcv-rows a) (tcv-rows b))))

(defun tui-canvas-diff (old new)
  "The runs of cells that differ, as a list of (ROW COL STRING FG).

A run is a maximal stretch of changed cells in one row that share a
colour, because that is exactly the unit the terminal can be told about
in one go: one cursor placement, one colour set, one write.  Splitting on
colour as well as on position is what keeps the writer from having to
think about either.

OLD may be NIL, or a different size, and then everything is a change —
which is the correct answer after a resize, where nothing is where it
was."
  (declare (type (or null tui-canvas) old) (type tui-canvas new))
  (let ((runs '())
        (full (not (tui-same-size-p old new))))
    (dotimes (row (tcv-rows new))
      (let ((col 0))
        (loop while (< col (tcv-cols new))
              do (let ((i (tcv-index new col row)))
                   (if (or full
                           (char/= (aref (tcv-chars new) i)
                                   (aref (tcv-chars old) i))
                           (/= (aref (tcv-fg new) i) (aref (tcv-fg old) i)))
                       ;; Start of a run: take everything that follows it
                       ;; while it keeps changing and keeps its colour.
                       (let* ((fg (aref (tcv-fg new) i))
                              (start col)
                              (end col))
                         (loop while (< end (tcv-cols new))
                               for j = (tcv-index new end row)
                               while (and (= (aref (tcv-fg new) j) fg)
                                          (or full
                                              (char/= (aref (tcv-chars new) j)
                                                      (aref (tcv-chars old) j))
                                              (/= (aref (tcv-fg new) j)
                                                  (aref (tcv-fg old) j))))
                               do (incf end))
                         (let ((s (make-string (- end start))))
                           (dotimes (k (- end start))
                             (setf (char s k)
                                   (aref (tcv-chars new)
                                         (tcv-index new (+ start k) row))))
                           (push (list row start s fg) runs))
                         (setf col end))
                       (incf col))))))
    (nreverse runs)))

(defun tui-canvas-copy! (dst src)
  "Make DST a copy of SRC, reusing its arrays when they are the right
size.  The frame loop keeps two canvases and swaps them; this is how the
one just drawn becomes the one to compare against next time, without
consing a new grid every frame.

DST may be NIL, and on the first frame after a start or a resize it
always is — there is no previous screen to compare against, which is
exactly what TUI-CANVAS-DIFF reads as \"repaint everything\".  Returns
the canvas to keep, which is why callers must use the return value
rather than assuming DST was filled in."
  (declare (type (or null tui-canvas) dst) (type tui-canvas src))
  (if (tui-same-size-p dst src)
      (progn (replace (tcv-chars dst) (tcv-chars src))
             (replace (tcv-fg dst) (tcv-fg src))
             dst)
      (let ((new (make-tui-canvas (tcv-cols src) (tcv-rows src))))
        (replace (tcv-chars new) (tcv-chars src))
        (replace (tcv-fg new) (tcv-fg src))
        new)))
