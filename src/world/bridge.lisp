;;;; world/bridge.lisp — the bridge experiments (§3.8).
;;;;
;;;; Two of §3.8's acceptance rows are not properties of a function; they
;;;; are results of a *published experiment*, and they only mean anything
;;;; run as that experiment.  This file is the apparatus.
;;;;
;;;;   Deneubourg binary bridge — two arms of equal length between nest and
;;;;   food.  There is no right answer, so any departure from an even split
;;;;   has to have been produced by the colony.  The claim is that traffic
;;;;   collapses onto one arm, and that *which* arm is not a property of
;;;;   the model.
;;;;
;;;;   Goss double bridge — one arm shorter.  Now there is a right answer.
;;;;   Nothing measures a length: ants on the short arm simply complete the
;;;;   round trip sooner, so they lay on it sooner and more often, and the
;;;;   asymmetry does the rest.
;;;;
;;;; An "arm" here is geometry, not code.  The apparatus is a wall across
;;;; the arena with two gaps in it, so every journey between nest and food
;;;; passes through one gap or the other and the choice is forced.  That is
;;;; the whole of it — there is no arm object, no route, and nothing in the
;;;; ant that knows a bridge exists.

(in-package #:antsim)

(defstruct (bridge (:constructor %make-bridge))
  "The apparatus, and the tally of who went through which gap.

Holds no simulation state: it is a description of where the walls are,
plus counters.  Removing it would change nothing about how the ants
behave, which is the point — the experiment must not be able to reach
into the model."
  (world nil :type (or null world))
  (colony nil :type (or null colony))
  (wall-y 0.0f0 :type f32)
  ;; gap centres, in x.  Two of them; a list rather than two slots so the
  ;; tally loop does not have to care how many arms there are.
  (gaps '() :type list)
  (counts nil :type (or null (simple-array (unsigned-byte 32) (*))))
  ;; straight-line nest -> gap -> food distance for each arm, which is
  ;; what makes one bridge "equal" and the other "unequal".  Recorded so a
  ;; test can state the ratio it is relying on instead of trusting the
  ;; coordinates to still mean what they meant when they were written.
  (lengths '() :type list))

(defun bridge-arm-length (nx ny fx fy bx by tx ty)
  "Nest -> the arm's bottom mouth -> its top mouth -> food, in metres.

Recorded so a test can state the length ratio it relies on, rather than
trusting a set of coordinates to still mean what they meant when they
were written."
  (declare (type f32 nx ny fx fy bx by tx ty))
  (flet ((d (x0 y0 x1 y1)
           (sqrt (+ (* (- x1 x0) (- x1 x0)) (* (- y1 y0) (- y1 y0))))))
    (+ (d nx ny bx by) (d bx by tx ty) (d tx ty fx fy))))

(defun add-bridge! (w &key (y-lo 0.20f0) (y-hi 0.40f0)
                           (corridor-width 0.06f0)
                           bottoms tops)
  "Add the solid parts of a bridge to W: a band from Y-LO to Y-HI that is
solid everywhere except for one corridor per arm.

BOTTOMS and TOPS give each arm's centre line where it leaves the lower
chamber and where it enters the upper one, left to right.  An arm whose
bottom and top differ is slanted, and therefore longer, without the fork
moving — which is exactly what an unequal-arm bridge needs.

Built as the **complement of the corridors**, never as a list of solid
pieces given by hand.  Authoring the solid parts directly is how a bridge
ends up with a third way through that nobody notices; the ants find it,
the traffic splits three ways, and the science gets blamed for a hole in
the wall.

This is the one implementation.  MAKE-BRIDGE-WORLD calls it, and so does
the `bridge` primitive in the scenario format (§6) — a bridge that meant
something different in JSON than it does in Lisp would be a very quiet
way to invalidate an acceptance result."
  (declare (type world w) (type f32 y-lo y-hi corridor-width))
  (assert (= (length bottoms) (length tops)) ()
          "a bridge needs the same number of bottom and top mouths")
  (assert (>= (length bottoms) 2) ()
          "a bridge needs at least two arms; got ~d" (length bottoms))
  (let ((h (* 0.5f0 corridor-width))
        (width (world-width w)))
    ;; everything left of the first arm
    (add-obstacle w (list 0.0f0 y-lo
                          (- (first bottoms) h) y-lo
                          (- (first tops) h) y-hi
                          0.0f0 y-hi))
    ;; an island between each adjacent pair
    (loop for (b0 b1) on bottoms
          for (t0 t1) on tops
          while b1
          do (add-obstacle w (list (+ b0 h) y-lo  (- b1 h) y-lo
                                   (- t1 h) y-hi  (+ t0 h) y-hi)))
    ;; and everything right of the last
    (add-obstacle w (list (+ (car (last bottoms)) h) y-lo
                          width y-lo  width y-hi
                          (+ (car (last tops)) h) y-hi)))
  (values))

(defun make-bridge-world (&key (width 0.70f0) (height 0.60f0)
                               ;; corridor mouths: x of each arm's centre
                               ;; line where it leaves the nest chamber
                               ;; and where it enters the food chamber
                               (bottoms '(0.28f0 0.36f0))
                               (tops '(0.28f0 0.36f0))
                               (corridor-width 0.06f0)
                               (y-lo 0.20f0) (y-hi 0.40f0)
                               (nest-x 0.32f0) (nest-y 0.10f0)
                               (food-x 0.32f0) (food-y 0.50f0)
                               (food-amount 500000.0f0)
                               (start 150) (capacity 4000)
                               (stock 400.0f0)
                               (seed +default-seed+))
  "Build a bridge apparatus and return a BRIDGE.

The shape is the one the experiments use, and the shape is the whole
point.  A band across the arena from Y-LO to Y-HI is solid except for two
corridors, so the nest chamber below and the food chamber above are
connected by exactly two routes.

**The two corridor mouths are adjacent at the bottom**, separated only by
the thickness of the island between them.  That is what makes this a
*fork*, and it is not a detail.  The first version of this file put the
two gaps 40 cm apart in a single wall, which is a perfectly good maze and
a useless experiment: an ant near one gap cannot smell the other, so it
takes whichever it wandered into and there is no choice to amplify.
Measured, that gave a 51/49 split that never moved — the model was fine,
the apparatus was not.  Deneubourg's bridge is a narrow Y so that both
arms fall within one ant's antennal span at the branch point.

BOTTOMS and TOPS give each arm's centre line at the two ends, so an arm
can be slanted to make it longer without moving the fork — which is
exactly what the unequal-arm variant needs.

The source is effectively unlimited by default.  Both rows are claims
about which arm the traffic *chooses*, and a source that ran dry mid-run
would put a starvation transient on top of the measurement."
  (let* ((w (make-world :width width :height height
                        :capacity capacity :seed seed))
         (h (* 0.5f0 corridor-width))
         (b0 (float (first bottoms) 1.0f0)) (b1 (float (second bottoms) 1.0f0))
         (t0 (float (first tops) 1.0f0))    (t1 (float (second tops) 1.0f0)))
    (declare (ignorable h))
    (add-bridge! w :y-lo y-lo :y-hi y-hi :corridor-width corridor-width
                   :bottoms (list b0 b1) :tops (list t0 t1))
    ;; walls before the colony: MAKE-COLONY rasterizes what is already
    ;; there into the new field's blocked mask (see ADD-OBSTACLE)
    (let ((c (add-colony w :name "home" :nest-x nest-x :nest-y nest-y
                           :nest-r 0.02f0 :capacity capacity :stock stock)))
      (add-food w food-x food-y 0.035f0 food-amount :quality 1.0f0)
      (world-seed-population! w c start)
      (%make-bridge
       :world w :colony c :wall-y (* 0.5f0 (+ y-lo y-hi))
       ;; the tally attributes a crossing to an arm by x at mid-height,
       ;; which is where each corridor's centre line sits
       :gaps (list (* 0.5f0 (+ b0 t0)) (* 0.5f0 (+ b1 t1)))
       :counts (make-array 2 :element-type '(unsigned-byte 32)
                             :initial-element 0)
       :lengths (list (bridge-arm-length nest-x nest-y food-x food-y
                                         b0 y-lo t0 y-hi)
                      (bridge-arm-length nest-x nest-y food-x food-y
                                         b1 y-lo t1 y-hi))))))

(defun binary-bridge (&key (seed +default-seed+) (start 150))
  "Deneubourg's binary bridge: two arms of equal length (§3.8).

Both corridors run straight up, mirrored about the nest–food axis, so the
arms are the same length to the last float.  There is no right answer
here, which is the design: any departure from an even split has to have
been produced by the colony."
  (make-bridge-world :seed seed :start start))

(defun double-bridge (&key (seed +default-seed+) (start 150))
  "Goss's double bridge: one arm longer than the other (§3.8).

The fork is unchanged — both corridors still leave the nest chamber side
by side — but arm 1 is slanted so it runs further and comes out well off
to the side of the food.  Arm 0 is the short one.

The corridors are the same *width*, so the arms differ in length and in
nothing else.  Making the long arm narrower would have produced the same
result for the wrong reason: crowding, not distance."
  (make-bridge-world :tops '(0.28f0 0.60f0) :seed seed :start start))

(defun bridge-tally! (b)
  "Count crossings of the wall since the last motion tick.

Called after WORLD-STEP!, which is when ANTS-PX/PY still hold where each
ant started the tick and the body table holds where it ended up.  A sign
change across WALL-Y is a crossing, and since the wall is solid
everywhere else it can only have happened through a gap — so the arm is
whichever gap centre is nearest in x.

Both directions are counted.  Traffic is the quantity the experiments
report, and an arm carries its foragers out as well as home."
  (declare (type bridge b))
  (let* ((w (bridge-world b))
         (a (world-ants w))
         (bd (world-bodies w))
         (ys (bodies-y bd))
         (xs (bodies-x bd))
         (wall (bridge-wall-y b))
         (gaps (bridge-gaps b))
         (counts (bridge-counts b)))
    (dotimes (i (ants-n a))
      (when (ant-live-p a i)
        (let* ((bi (aref (ants-body a) i))
               (y0 (aref (ants-py a) i))
               (y1 (aref ys bi)))
          (when (or (and (< y0 wall) (>= y1 wall))
                    (and (>= y0 wall) (< y1 wall)))
            (let ((x (aref xs bi))
                  (best 0) (bestd 1.0f10) (k 0))
              (declare (type f32 x bestd))
              (dolist (g gaps)
                (let ((d (abs (- x (float g 1.0f0)))))
                  (when (< d bestd) (setf bestd d best k)))
                (incf k))
              (incf (aref counts best)))))))
    (values)))

(defun bridge-run! (b ticks)
  "Run the apparatus, tallying every tick."
  (declare (type bridge b) (type fixnum ticks))
  (dotimes (i ticks)
    (world-step! (bridge-world b))
    (bridge-tally! b))
  (values))

(defun bridge-reset-counts! (b)
  "Zero the tally, to measure a later window without the start-up in it."
  (declare (type bridge b))
  (fill (bridge-counts b) 0)
  (values))

(defun bridge-share (b)
  "Each arm's share of total crossings, as a list of floats summing to 1."
  (declare (type bridge b))
  (let ((total (reduce #'+ (bridge-counts b))))
    (if (zerop total)
        (mapcar (constantly 0.0f0) (bridge-gaps b))
        (map 'list (lambda (n) (/ (float n 1.0f0) (float total 1.0f0)))
             (bridge-counts b)))))

(defun bridge-winner (b)
  "Index of the arm carrying the most traffic, or NIL if none moved."
  (declare (type bridge b))
  (let ((counts (bridge-counts b)))
    (when (plusp (reduce #'+ counts))
      (let ((best 0))
        (dotimes (i (length counts))
          (when (> (aref counts i) (aref counts best)) (setf best i)))
        best))))
