;;;; world/trials.lisp — the §3.8 rows the bridges do not cover.
;;;;
;;;; world/bridge.lisp is the apparatus for the two *topology* rows, where
;;;; the question is which of two routes the traffic takes.  This file is
;;;; the apparatus for the three that remain, and they ask different
;;;; questions with different geometry:
;;;;
;;;;   Beckers, Deneubourg & Goss (1993), "Modulation of trail laying in
;;;;   Lasius niger and its role in the collective selection of a food
;;;;   source", J. Insect Behavior 6:751.  Two sources, equal distance,
;;;;   different sucrose concentration.  The colony selects the richer
;;;;   one — and below a concentration threshold a forager feeds and walks
;;;;   home *without laying*, so a poor source is exploited and never
;;;;   recruited to.  Two rows, one apparatus.
;;;;
;;;;   §3.12's competition row.  Two colonies, one contested source.  The
;;;;   nearer colony wins it, and raising ε degrades both colonies' trail
;;;;   fidelity — which is the claim per-colony fields were built for in
;;;;   M1 and that nothing has been able to test until now.
;;;;
;;;; As with the bridges: the geometry is the experiment.  There is no
;;;; "source A" anywhere in the ant, and no colony knows a rival exists.

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Beckers — two sources at equal distance (§3.8)
;;; --------------------------------------------------------------------

(defstruct (choice-trial (:constructor %make-choice-trial))
  (world nil :type (or null world))
  (colony nil :type (or null colony))
  (foods '() :type list))               ; in the order they were placed

(defun make-two-source-world (&key (width 0.60f0) (height 0.50f0)
                                   (nest-x 0.30f0) (nest-y 0.06f0)
                                   (distance 0.32f0)
                                   (half-angle 0.42f0)
                                   (quality-a 1.0f0) (quality-b 0.4f0)
                                   (amount 500000.0f0)
                                   (radius 0.030f0)
                                   (start 250) (capacity 4000)
                                   (stock 400.0f0)
                                   (seed +default-seed+))
  "Two sources, the same distance from the nest, differing in QUALITY.

**The fork is at the nest door, and it has to be.**  The bridge file
records the failure mode at length: two options an ant cannot smell at
once are not a choice, they are two experiments run side by side, and the
result is a 50/50 split that never moves.  Here both trails begin at the
same nest, so a departing forager stands where both are readable — the
geometry does the job the narrow Y does on the bridge, without walls.

HALF-ANGLE is each source's angular separation from the nest–north axis,
so the two are 2·HALF-ANGLE apart as seen from the nest and exactly
DISTANCE away from it.  Equal distance is the control: any selection has
to have come from quality, because there is nothing else left for it to
have come from.

The sources are effectively unlimited by default, for the reason the
bridges' is: the claim is about which source the traffic *chooses*, and
one running dry mid-run would lay a starvation transient over the
measurement.

Colony size is 250 — the bridge's density window applies here too and for
the same reason: too few ants and the nonlinearity never latches, too
many and crowding at the pile starts doing the selecting."
  (let* ((w (make-world :width width :height height
                        :capacity capacity :seed seed))
         (d (float distance 1.0f0))
         (ha (float half-angle 1.0f0))
         (nx (float nest-x 1.0f0)) (ny (float nest-y 1.0f0))
         (c (add-colony w :name "home" :nest-x nx :nest-y ny
                          :nest-r 0.02f0 :capacity capacity :stock stock))
         ;; north is +y; A lies to the left of it, B to the right
         (ax (- nx (* d (sin ha)))) (ay (+ ny (* d (cos ha))))
         (bx (+ nx (* d (sin ha)))) (by (+ ny (* d (cos ha))))
         (fa (add-food w ax ay radius amount :quality (float quality-a 1.0f0)))
         (fb (add-food w bx by radius amount :quality (float quality-b 1.0f0))))
    (world-seed-population! w c start)
    (%make-choice-trial :world w :colony c :foods (list fa fb))))

(defun make-poor-source-world (&key (width 0.60f0) (height 0.50f0)
                                    (nest-x 0.30f0) (nest-y 0.06f0)
                                    (distance 0.32f0)
                                    (quality 0.15f0)
                                    (amount 500000.0f0)
                                    (radius 0.030f0)
                                    (start 250) (capacity 4000)
                                    (stock 400.0f0)
                                    (seed +default-seed+))
  "One source, directly north of the nest, of QUALITY.

The other half of Beckers: with a single source there is nothing to
choose between, so the question is not *which* but *whether* — does a
colony that is eating from a source also recruit to it.  Below
*trail-quality-threshold* the answer must be no, and both halves of that
answer have to hold at once: food is taken (the ants are not refusing to
feed) and no trail forms (they are refusing to advertise)."
  (let* ((w (make-world :width width :height height
                        :capacity capacity :seed seed))
         (nx (float nest-x 1.0f0)) (ny (float nest-y 1.0f0))
         (c (add-colony w :name "home" :nest-x nx :nest-y ny
                          :nest-r 0.02f0 :capacity capacity :stock stock))
         (f (add-food w nx (+ ny (float distance 1.0f0)) radius amount
                      :quality (float quality 1.0f0))))
    (world-seed-population! w c start)
    (%make-choice-trial :world w :colony c :foods (list f))))

(defun choice-run! (tr ticks)
  "Run TICKS motion ticks."
  (declare (type choice-trial tr))
  (world-run! (choice-trial-world tr) ticks)
  tr)

(defun choice-reset-counts! (tr)
  "Zero the per-source visit tallies.

The same role BRIDGE-RESET-COUNTS! has: the opening minutes of a run are
the colony discovering the arena, and counting them measures how long a
random walk takes to stumble on a pile rather than what the trails then
did with it."
  (declare (type choice-trial tr))
  (dolist (f (choice-trial-foods tr))
    (setf (food-visits f) 0))
  tr)

(defun choice-shares (tr)
  "Each source's share of feeding visits, in placement order.

NIL if nothing has visited anything — a distinct outcome from an even
split, and one that must never be reported as one."
  (declare (type choice-trial tr))
  (let ((total (reduce #'+ (choice-trial-foods tr) :key #'food-visits)))
    (when (plusp total)
      (mapcar (lambda (f) (/ (float (food-visits f) 1.0f0) total))
              (choice-trial-foods tr)))))

;;; --------------------------------------------------------------------
;;; §3.12 — two colonies and one contested source
;;; --------------------------------------------------------------------

(defstruct (competition (:constructor %make-competition))
  (world nil :type (or null world))
  (near nil :type (or null colony))
  (far nil :type (or null colony))
  (food nil :type (or null food)))

(defun make-competition-world (&key (width 0.80f0) (height 0.40f0)
                                    (near-x 0.16f0) (far-x 0.72f0)
                                    (nest-y 0.20f0)
                                    (food-x 0.32f0) (food-y 0.20f0)
                                    (amount 500000.0f0)
                                    (radius 0.030f0)
                                    (start 250) (capacity 4000)
                                    (stock 400.0f0)
                                    (seed +default-seed+))
  "Two colonies on one arena with a single source between them, placed so
one nest is nearer it than the other (§3.12).

The default geometry puts the source 16 cm from the near nest and 40 cm
from the far one — a ratio of 2.5, well clear of the 1.73 the double
bridge resolves, because this row has to survive two colonies' worth of
noise rather than one colony's.

Nothing here tells an ant a rival exists.  The colonies interact through
exactly two channels and both were built in earlier milestones: their
*fields* are separate and read through ε (§3.12, SENSE-AT), and their
*ants* recognise each other by colony id at the antennae (M3), so a
stranger is avoided harder, never fed and never believed.  What this row
asserts is a consequence of those two and of the geometry."
  (let* ((w (make-world :width width :height height
                        :capacity capacity :seed seed))
         (near (add-colony w :name "near" :nest-x (float near-x 1.0f0)
                             :nest-y (float nest-y 1.0f0) :nest-r 0.02f0
                             :capacity capacity :stock stock))
         (far (add-colony w :name "far" :nest-x (float far-x 1.0f0)
                            :nest-y (float nest-y 1.0f0) :nest-r 0.02f0
                            :capacity capacity :stock stock))
         (f (add-food w (float food-x 1.0f0) (float food-y 1.0f0)
                      radius amount :quality 1.0f0)))
    (world-seed-population! w near start)
    (world-seed-population! w far start)
    (%make-competition :world w :near near :far far :food f)))

(defun competition-run! (cm ticks)
  (declare (type competition cm))
  (world-run! (competition-world cm) ticks)
  cm)

(defun competition-share (cm)
  "The near colony's share of everything the two of them carried home.

NIL if neither has carried anything, which is not a tie."
  (declare (type competition cm))
  (let* ((n (colony-harvested (competition-near cm)))
         (f (colony-harvested (competition-far cm)))
         (total (+ n f)))
    (when (plusp total) (/ n total))))

(defun colony-trail-fidelity (c &key (fraction 0.10f0))
  "How concentrated a colony's trail field is: the share of its total
pheromone lying in the strongest FRACTION of the cells that hold any.

A route is a *thin* structure.  A colony with a working trail has most of
its mark on a narrow line, so a small share of the marked cells holds a
large share of the total; a colony whose foragers are scattered has the
same total smeared over everything they walked on.  That is the
difference this number is for, and it is why the measure is a
concentration rather than a maximum — a maximum says how strong the best
cell is, and ε does not attack the best cell, it attacks the *contrast*
between the line and its surroundings.

NIL for a field with nothing in it."
  (declare (type colony c))
  (let* ((f (colony-field c))
         (v (field-c f))
         (n (length (the f32v v)))
         (marked (make-array 0 :element-type 'single-float
                               :adjustable t :fill-pointer 0)))
    (declare (type fixnum n))
    (dotimes (i n)
      (let ((x (aref (the f32v v) i)))
        (when (> x 0.0f0) (vector-push-extend x marked))))
    (when (plusp (length marked))
      (let* ((sorted (sort (coerce marked '(simple-array single-float (*)))
                           #'>))
             (total (reduce #'+ sorted))
             (top (max 1 (round (* (float fraction 1.0f0) (length sorted))))))
        (when (plusp total)
          (/ (reduce #'+ sorted :end top) total))))))
