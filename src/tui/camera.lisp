;;;; tui/camera.lisp — the terminal camera (§5.6).
;;;;
;;;; Its own camera rather than render/view.lisp's, and the reason is not
;;;; laziness in either direction.  VIEW is pure arithmetic and would work
;;;; here, but it ships as a component of antsim/render, so reaching it
;;;; would mean splitting a new system out of the render system and
;;;; rewiring the one path that is known to work — an invasive change to
;;;; GL code to buy forty lines of arithmetic.
;;;;
;;;; The needs are different anyway.  A window pans by pixels under a
;;;; dragged cursor and zooms anchored at that cursor; a terminal pans by
;;;; whole cells under the arrow keys and has no cursor to anchor
;;;; anything to.  What it does have, and what a window does not, is a
;;;; cell that is not square — which is the one piece of arithmetic in
;;;; this file that must not be got wrong.

(in-package #:antsim)

(defparameter *tui-cell-aspect* 2.0f0
  "Cell height divided by cell width, as the terminal actually draws it.

Two is right for very nearly every terminal and monospace font, and the
consequence of pretending it is one is immediate and ugly: a round nest
renders as an ellipse twice as wide as it is tall, and every distance
read off the screen vertically is wrong by a factor of two.  It is a
parameter rather than a constant because a font that disagrees is
possible, not because anything here is unsure.")

(defstruct (tui-camera (:conc-name tcam-) (:constructor %make-tui-camera))
  (cx 0.5f0 :type f32)                  ; centre, world metres
  (cy 0.5f0 :type f32)
  (mpc 0.005f0 :type f32))              ; metres per cell *column*

(defun make-tui-camera (&key (cx 0.5f0) (cy 0.5f0) (mpc 0.005f0))
  (%make-tui-camera :cx (float cx 1.0f0) :cy (float cy 1.0f0)
                    :mpc (max 1.0f-6 (float mpc 1.0f0))))

(declaim (inline tcam-mpr))
(defun tcam-mpr (cam)
  "Metres per cell *row*.  Derived from the column figure and the cell
aspect, never stored — storing both is how a camera ends up able to
represent a cell shape the terminal cannot draw."
  (declare (type tui-camera cam))
  (* (tcam-mpc cam) *tui-cell-aspect*))

(defun tui-visible-span (cam cols rows)
  "Values: the world width and height currently on screen, in metres."
  (declare (type tui-camera cam) (type fixnum cols rows))
  (values (* cols (tcam-mpc cam))
          (* rows (tcam-mpr cam))))

(defun tui-fit (w cols rows &key (margin 1.06f0))
  "A camera framing the whole arena, with a little air around it — what
the `f` key restores.

A column spans MPC metres and a row spans MPC times the aspect, so the
two constraints are cols*mpc >= width and rows*mpc*aspect >= height, and
the fit is whichever of them is the looser."
  (declare (type world w) (type fixnum cols rows))
  (let* ((cols (max 1 cols))
         (rows (max 1 rows))
         (mpc (* margin
                 (max (/ (world-width w) cols)
                      (/ (world-height w) (* rows *tui-cell-aspect*))))))
    (make-tui-camera :cx (* 0.5f0 (world-width w))
                     :cy (* 0.5f0 (world-height w))
                     :mpc mpc)))

(defun tui-world->cell (cam cols rows x y)
  "World metres to a cell index, origin top-left.

Values: column, row.  Both may be outside the grid — clamping here would
silently pile everything off-screen onto the border, which looks like a
swarm against the edge rather than like something out of view."
  (declare (type tui-camera cam) (type fixnum cols rows) (type f32 x y))
  (values (floor (+ (* 0.5f0 cols) (/ (- x (tcam-cx cam)) (tcam-mpc cam))))
          ;; world y is up, terminal rows go down
          (floor (+ (* 0.5f0 rows) (/ (- (tcam-cy cam) y) (tcam-mpr cam))))))

(defun tui-cell->world (cam cols rows col row)
  "The world point at the *centre* of a cell.  The inverse of
TUI-WORLD->CELL up to the half-cell that rounding threw away, and what
the field is sampled at."
  (declare (type tui-camera cam) (type fixnum cols rows col row))
  (values (+ (tcam-cx cam) (* (- (+ col 0.5f0) (* 0.5f0 cols)) (tcam-mpc cam)))
          (- (tcam-cy cam) (* (- (+ row 0.5f0) (* 0.5f0 rows)) (tcam-mpr cam)))))

(defun tui-clamp! (cam w cols rows)
  "Keep the arena on the screen.

The GL camera deliberately does *not* clamp, and it is right not to: in a
window you can see that you have flown off the arena, and drag back.  A
terminal full of blank cells has no scroll bar, no minimap and no
momentum to tell you which way you came from — it is indistinguishable
from a program that has stopped working, and the way out is to quit.

So: when the arena is larger than the screen, the visible rectangle is
held inside it; when it is smaller, there is nothing to pan and the arena
is simply centred."
  (declare (type tui-camera cam) (type world w) (type fixnum cols rows))
  (multiple-value-bind (vw vh) (tui-visible-span cam cols rows)
    (let ((ww (world-width w)) (wh (world-height w)))
      (setf (tcam-cx cam)
            (if (>= vw ww)
                (* 0.5f0 ww)
                (clampf (tcam-cx cam) (* 0.5f0 vw) (- ww (* 0.5f0 vw)))))
      (setf (tcam-cy cam)
            (if (>= vh wh)
                (* 0.5f0 wh)
                (clampf (tcam-cy cam) (* 0.5f0 vh) (- wh (* 0.5f0 vh)))))))
  cam)

(defun tui-pan! (cam w cols rows dcol drow)
  "Pan by whole cells — DCOL columns right, DROW rows *down*.

Cells rather than metres because that is what the key press means: one
press moves the picture by one character, whatever the zoom, and the
picture therefore moves by the same visible amount every time.  Panning
by a fixed distance in metres would crawl when zoomed out and fly when
zoomed in."
  (declare (type tui-camera cam) (type world w) (type fixnum cols rows dcol drow))
  (incf (tcam-cx cam) (* dcol (tcam-mpc cam)))
  (decf (tcam-cy cam) (* drow (tcam-mpr cam)))  ; rows down, world y up
  (tui-clamp! cam w cols rows))

(defun tui-zoom! (cam w cols rows factor)
  "Zoom about the centre of the screen by FACTOR — larger is closer.

About the centre, and not about a cursor, because a terminal has no
cursor to zoom about.  The centre is therefore the fixed point, which is
also the thing the user is looking at."
  (declare (type tui-camera cam) (type world w) (type fixnum cols rows)
           (type f32 factor))
  (setf (tcam-mpc cam)
        ;; A floor on the near end so a run of zoom-ins cannot reach zero
        ;; and divide by it; a ceiling on the far end at a few arenas
        ;; wide, past which everything is one character and there is
        ;; nothing further to see.
        (clampf (/ (tcam-mpc cam) factor)
                1.0f-6
                (max 1.0f-6 (/ (* 4.0f0 (max (world-width w) (world-height w)))
                               (max 1 cols)))))
  (tui-clamp! cam w cols rows))
