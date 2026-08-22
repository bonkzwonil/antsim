;;;; tui/draw.lisp — one world, one canvas (§5.6).
;;;;
;;;; A pure function, and that is the whole design: TUI-DRAW-WORLD! reads
;;;; the same exported accessors the GL renderer reads and writes
;;;; characters into a grid.  It opens nothing, owns nothing and signals
;;;; on nothing, so the tests for it run in the everywhere-runnable suite
;;;; with no terminal and no GPU.
;;;;
;;;; What it deliberately is not: a text transcription of the window.
;;;; There is no vector ant, no articulated leg, no inspector.  A cell is
;;;; a very large pixel — at a comfortable zoom one cell is a couple of
;;;; millimetres, which is most of an ant — and the honest thing to do
;;;; with a pixel that size is to say where the ants are and which way
;;;; they are pointing.  Everything here follows from that.

(in-package #:antsim)

;;; --- what a cell can say ----------------------------------------------
;;;
;;; The glyphs are chosen to not collide, which sounds obvious and is the
;;; kind of thing that is got wrong once and then read as a bug in the
;;; simulation.  If the pheromone ramp contained `#` there would be no
;;; telling a heavy trail from a wall; if it contained `-` there would be
;;; no telling one from an ant walking east in ASCII mode.  So the ramp
;;; keeps to punctuation nothing else uses.

(defparameter *tui-field-ramp* " .,:;+*"
  "Pheromone density, lightest first.  A space at the bottom so that an
empty cell costs nothing to draw and shows whatever is under it.")

(defparameter *tui-terrain-char* #\#)
(defparameter *tui-food-char*    #\o)
(defparameter *tui-nest-char*    #\@)
(defparameter *tui-corpse-char*  #\x)

(defparameter *tui-ant-glyphs-ascii* "-\\|/-\\|/"
  "Eight headings, four shapes.

The set the ASCII terminal gets, and its limitation is worth stating
plainly rather than discovering: `\\` is drawn for an ant heading
north-west *and* for one heading south-east, because the character is a
stroke and a stroke has no arrowhead.  What survives is the axis of
travel, not the direction along it.  That is a real loss — it is why
Unicode is the default — but an axis is still most of what the eye is
reading when it looks at a trail, and it is what an ASCII terminal can
honestly show.")

(defparameter *tui-ant-glyphs-unicode* "→↘↓↙←↖↑↗"
  "Eight headings, eight glyphs.  In *screen* order — east, south-east,
south — because that is the order TUI-ANT-GLYPH indexes them in.")

(defun tui-ant-glyph (heading &optional (charset :unicode))
  "The glyph for an ant on this bearing.

HEADING is the model's: radians, zero at +x, counter-clockwise, as
ANT-MOTION-STEP! uses it.  The screen's is the mirror of that, because
world y is up and terminal rows go down — so the table is indexed by the
*negated* angle.

This is not a fussy detail.  Indexed by the raw heading the picture is
wrong in exactly half of it: the ants above the nest point correctly and
the ants below it point at their own reflection, which reads as two
columns of traffic going the same way.  A rosette of sixteen ants
pointing outward is the cheapest way to see it, and there is a test that
draws one."
  (declare (type f32 heading))
  (let* ((glyphs (ecase charset
                   (:unicode *tui-ant-glyphs-unicode*)
                   (:ascii *tui-ant-glyphs-ascii*)))
         (n (length glyphs))
         (screen (mod (- heading) (* 2 (coerce pi 'single-float))))
         (i (mod (round (/ (* screen n) (* 2 (coerce pi 'single-float)))) n)))
    (char glyphs i)))

;;; --- colour ------------------------------------------------------------
;;;
;;; The same meanings the window's ANT-STATE-RGB gives, in the sixteen
;;; colours every terminal agrees about.  Two views of one world should
;;; not disagree about what green means.

(defconstant +tui-grey+   90)
(defconstant +tui-red+    31)
(defconstant +tui-green+  92)
(defconstant +tui-yellow+ 93)
(defconstant +tui-white+  97)
(defconstant +tui-dim-green+ 32)
(defconstant +tui-magenta+   95)

(defparameter *tui-colony-colours* #(97 96 95 94 91 93)
  "One per colony, for a world that has more than one.  A single-colony
world uses none of this and is coloured by state alone — the same rule
TRIBE-NUMBER follows for the shaders, and for the same reason: the
picture of one colony should not change because the code learned to draw
two.")

(defun tui-ant-colour (a i c ncolonies)
  "The colour for one ant.  Spent outranks everything, exactly as it does
in ANT-DISPLAY-STATE, and for the same reason: an ant below the energy it
needs to set out is not going anywhere, whatever it is nominally doing,
and a nest quietly filling with them is the end of a colony.  Drawn in
ordinary resting grey it is invisible."
  (declare (type ants a) (type fixnum i ncolonies))
  (let ((state (aref (ants-state a) i)))
    (cond ((and c (< (aref (ants-energy a) i) (colony-energy-threshold c)))
           +tui-red+)
          ((= state +ant-returning+) +tui-green+)
          ((= state +ant-at-food+) +tui-yellow+)
          ((= state +ant-in-nest+) +tui-grey+)
          ((< ncolonies 2) +tui-white+)
          (t (aref *tui-colony-colours*
                   (mod (aref (ants-colony a) i)
                        (length *tui-colony-colours*)))))))

;;; --- the frame ---------------------------------------------------------

(defun tui-disc! (cv cam cols rows top x y r char fg)
  "Fill the cells covered by a world-space disc.

Walked over the disc's own bounding box in cell space rather than over
the whole grid, so a food source costs what a food source is worth.  A
disc smaller than a cell still marks its centre cell — a source that has
been eaten down below the resolution of the screen has not stopped
existing, and blinking out of the picture the moment it gets small is how
a watcher concludes it was taken away."
  (declare (type tui-canvas cv) (type tui-camera cam)
           (type fixnum cols rows top) (type f32 x y r))
  (multiple-value-bind (c0 r0) (tui-world->cell cam cols rows (- x r) (+ y r))
    (multiple-value-bind (c1 r1) (tui-world->cell cam cols rows (+ x r) (- y r))
      (loop for row from (max 0 r0) to (min (1- rows) r1)
            do (loop for col from (max 0 c0) to (min (1- cols) c1)
                     do (multiple-value-bind (wx wy)
                            (tui-cell->world cam cols rows col row)
                          (when (<= (+ (sqf (- wx x)) (sqf (- wy y))) (sqf r))
                            (tui-put! cv col (+ top row) char fg)))))))
  ;; The centre, unconditionally, for the disc that fell between cells.
  (multiple-value-bind (col row) (tui-world->cell cam cols rows x y)
    (tui-put! cv col (+ top row) char fg))
  cv)

(defun tui-draw-world! (cv w cam &key (top 0) (colony 0) (charset :unicode)
                                      (colour t))
  "Draw W into CV through CAM, starting at canvas row TOP.

COLONY selects whose pheromone field is shaded — a field is per-colony
and there is no such thing as the trail of a world.  Everything else is
drawn for every colony at once."
  (declare (type tui-canvas cv) (type world w) (type tui-camera cam)
           (type fixnum top colony))
  (let* ((cols (tcv-cols cv))
         (rows (max 0 (- (tcv-rows cv) top)))
         (colonies (world-colonies w))
         (nc (length colonies))
         (c (nth (min colony (max 0 (1- nc))) colonies))
         (field (and c (colony-field c)))
         (ramp *tui-field-ramp*)
         (nramp (length ramp))
         ;; One reading per frame, not one per cell.  A trail is two
         ;; orders of magnitude below *trail-cap* in practice, so
         ;; normalising against the cap shows a blank arena with one
         ;; bright dot in it and reads as a broken field.  Against the
         ;; current maximum, and on a log scale, the shape of the trail
         ;; is visible from the first packet onward.
         (fmax (if field (field-max field) 0.0f0))
         (norm (if (> fmax 1.0f-6) (/ 1.0f0 (log (+ 1.0f0 fmax))) 0.0f0)))
    (declare (type fixnum cols rows))
    (when (or (<= cols 0) (<= rows 0))
      (return-from tui-draw-world! cv))
    (flet ((fg (code) (if colour code +tui-default+)))
      ;; --- the field, and the terrain standing in it -------------------
      (when field
        (dotimes (row rows)
          (dotimes (col cols)
            (multiple-value-bind (wx wy) (tui-cell->world cam cols rows col row)
              (cond
                ;; Outside the arena, and this test has to come first.
                ;; FIELD-AT and FIELD-BLOCKED-P clamp to the edge cell
                ;; rather than signalling — the right choice for the ant
                ;; loop, which never asks about a point outside the
                ;; world, and a trap here, where zooming out until the
                ;; arena is smaller than the terminal asks about
                ;; thousands of them.  Without this the edge row and
                ;; column smear outward across the whole screen and the
                ;; arena appears to have no boundary at all.
                ((or (< wx 0.0f0) (> wx (world-width w))
                     (< wy 0.0f0) (> wy (world-height w)))
                 nil)
                ;; The pre-rasterised obstacle mask.  Every wall, block
                ;; and bridge rail in the world is already burned into
                ;; it, so there is no polygon scan here and no
                ;; POINT-IN-POLYGON-P per cell.
                ((field-blocked-p field wx wy)
                 (tui-put! cv col (+ top row) *tui-terrain-char* (fg +tui-grey+)))
                ((> norm 0.0f0)
                 (let* ((v (field-at field wx wy))
                        (i (if (<= v 0.0f0)
                               0
                               (min (1- nramp)
                                    (floor (* (log (+ 1.0f0 v)) norm nramp))))))
                   (when (> i 0)
                     (tui-put! cv col (+ top row) (char ramp i)
                               (fg +tui-dim-green+))))))))))
      ;; --- food ---------------------------------------------------------
      ;; FOOD-CURRENT-RADIUS, never FOOD-R: the latter is the radius the
      ;; scenario authored at the starting amount, and the pile shrinks as
      ;; it is eaten.  Drawing the authored one shows a full source right
      ;; up to the moment it vanishes.
      (dolist (f (world-foods w))
        (unless (food-empty-p f)
          (tui-disc! cv cam cols rows top
                     (food-x f) (food-y f) (food-current-radius f)
                     *tui-food-char* (fg +tui-yellow+))))
      ;; --- nests --------------------------------------------------------
      (loop for col in colonies
            for k from 0
            do (tui-disc! cv cam cols rows top
                          (colony-nest-x col) (colony-nest-y col)
                          (colony-nest-r col)
                          *tui-nest-char*
                          (fg (if (< nc 2)
                                  +tui-magenta+
                                  (aref *tui-colony-colours*
                                        (mod k (length *tui-colony-colours*)))))))
      ;; --- corpses ------------------------------------------------------
      ;; Only reachable through the body table: an ant's slot is freed
      ;; when it dies, so there is no ant left to iterate.
      (let ((b (world-bodies w)))
        (when b
          (dotimes (i (bodies-n b))
            (when (= (aref (bodies-kind b) i) +body-corpse+)
              (multiple-value-bind (col row)
                  (tui-world->cell cam cols rows
                                   (aref (bodies-x b) i) (aref (bodies-y b) i))
                (tui-put! cv col (+ top row) *tui-corpse-char* (fg +tui-red+)))))))
      ;; --- ants, last, because they are the point ------------------------
      (let ((a (world-ants w))
            (b (world-bodies w)))
        (when (and a b)
          ;; ANTS-N is a high-water mark and not a population: slots below
          ;; it are freed and reused, and drawing one shows an ant that
          ;; died some time ago standing exactly where it fell.
          (dotimes (i (ants-n a))
            (when (ant-live-p a i)
              (let* ((bi (aref (ants-body a) i))
                     (ci (aref (ants-colony a) i))
                     (ac (nth ci colonies)))
                (multiple-value-bind (col row)
                    (tui-world->cell cam cols rows
                                     (aref (bodies-x b) bi)
                                     (aref (bodies-y b) bi))
                  (tui-put! cv col (+ top row)
                            (tui-ant-glyph (aref (ants-heading a) i) charset)
                            (fg (tui-ant-colour a i ac nc)))))))))))
  cv)

(defun tui-frame (w &key (cols 100) (rows 40) camera (colony 0)
                         (charset :unicode) (colour nil) status)
  "A whole frame as a canvas: the status line, then the world.

The seam the tests and the REPL both come in through.  Nothing here
touches a terminal, so `(princ (tui-canvas-string (tui-frame w)))` prints
a colony from a bare SBCL with no graphics stack anywhere in the image."
  (declare (type world w) (type fixnum cols rows))
  (let* ((cv (make-tui-canvas cols rows))
         (top (if status 1 0))
         (cam (or camera (tui-fit w cols (max 1 (- rows top))))))
    (when status
      (tui-write! cv 0 0 (tui-status w :colony colony :cols cols)
                  (if colour +tui-white+ +tui-default+)))
    (tui-draw-world! cv w cam :top top :colony colony
                              :charset charset :colour colour)
    cv))
