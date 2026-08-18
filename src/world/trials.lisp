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

(defun make-crossing-world (&key (width 0.70f0) (height 0.70f0)
                                 (inset 0.10f0)
                                 (amount 500000.0f0)
                                 (radius 0.030f0)
                                 (start 250) (capacity 4000)
                                 (stock 400.0f0)
                                 (seed +default-seed+))
  "Two colonies whose routes cross, each with a source of its own.

MAKE-COMPETITION-WORLD is the apparatus for the *food* half of §3.12 and
it is the wrong one for the ε half — measured, fidelity there is flat in
ε from 0.0 to 1.0, and the reason is geometry rather than model: the two
nests sit either side of one pile, so each colony's field lies almost
entirely where the other's does not and there is nothing for ε to
confuse.

Here the nests are at two opposite corners and each colony's source is at
the corner diagonally across from its own nest, so the routes form an X
and the fields overlap along their whole length at an angle.  **There is
nothing to compete for** — each colony has its own pile — so anything ε
does to the trails is ε acting on the trails, and not two colonies
fighting over lunch.

Returns a COMPETITION whose FOOD slot holds the near colony's source; the
far colony's is the other one in WORLD-FOODS."
  (let* ((w (make-world :width width :height height
                        :capacity capacity :seed seed))
         (lo (float inset 1.0f0))
         (hx (- (float width 1.0f0) lo)) (hy (- (float height 1.0f0) lo))
         (a (add-colony w :name "sw" :nest-x lo :nest-y lo :nest-r 0.02f0
                          :capacity capacity :stock stock))
         (b (add-colony w :name "se" :nest-x hx :nest-y lo :nest-r 0.02f0
                          :capacity capacity :stock stock))
         ;; sw's food is at the north-east; se's at the north-west
         (fa (add-food w hx hy radius amount :quality 1.0f0)))
    (add-food w lo hy radius amount :quality 1.0f0)
    (world-seed-population! w a start)
    (world-seed-population! w b start)
    (%make-competition :world w :near a :far b :food fa)))

(defun cull-foragers! (w c fraction)
  "Kill FRACTION of COLONY C's ants that are currently out of the nest.

The §3.8 task-reallocation row in the form the literature runs it: remove
the foragers and see whether the colony makes more.  A forager here is an
ant not presently in the nest, which is the operational definition an
experimenter has as well.

Selected by a stride through the table rather than at random, so the row
measures the colony's response and not a draw — and so a failure is
reproducible.  Returns how many were killed."
  (declare (type world w) (type colony c) (type f32 fraction))
  (let* ((a (world-ants w))
         (cid (colony-id c))
         (victims '())
         (k 0))
    (declare (type fixnum k))
    (dotimes (i (ants-n a))
      (when (and (ant-live-p a i)
                 (= (aref (ants-colony a) i) cid)
                 (/= (aref (ants-state a) i) +ant-in-nest+))
        (push i victims)))
    (let* ((v (nreverse victims))
           (n (length v))
           (want (round (* fraction n))))
      (when (plusp want)
        ;; every (n/want)th one, so the sample is spread over the table
        ;; rather than taken off one end of it
        (let ((stride (max 1 (floor n want))))
          (loop for i in v
                for j from 0
                while (< k want)
                when (zerop (mod j stride))
                  do (kill-ant w c i) (incf k)))))
    k))

(defun count-foragers (w c)
  "How many of C's ants are out of the nest right now."
  (declare (type world w) (type colony c))
  (let ((a (world-ants w)) (cid (colony-id c)) (k 0))
    (declare (type fixnum k))
    (dotimes (i (ants-n a) k)
      (when (and (ant-live-p a i)
                 (= (aref (ants-colony a) i) cid)
                 (/= (aref (ants-state a) i) +ant-in-nest+))
        (incf k)))))

(defun colony-route-fidelity (c fx fy &key (half-width 0.045f0))
  "The share of C's pheromone lying within HALF-WIDTH of the straight line
from its nest to (FX, FY).

**COLONY-TRAIL-FIDELITY measures the wrong thing for ε and this measures
the right one.**  Concentration says how *thin* a colony's structure is;
it does not say whether that structure goes anywhere useful.  Measured on
crossing routes, raising ε from 0 to 1 pushed concentration *up*, 0.496
to 0.601, while both colonies' harvest fell — which is exactly what a
merged trail network looks like.  Two colonies reading each other's marks
converge on one shared set of roads, and a shared set of roads is thinner
than two separate ones and leads half of each colony to the other's food.

So fidelity, for §3.12's purposes, is *correctness*: how much of what a
colony has laid down lies on the way to its own source.  A corridor
rather than an exact line, because a real trail has width — HALF-WIDTH
defaults to about three packet radii.

NIL for a field with nothing in it."
  (declare (type colony c) (type f32 fx fy half-width))
  (let* ((f (colony-field c))
         (v (field-c f))
         (cw (field-w f)) (ch (field-h f))
         (cell (field-cell f))
         (ox (field-origin-x f)) (oy (field-origin-y f))
         (ax (colony-nest-x c)) (ay (colony-nest-y c))
         (dx (- fx ax)) (dy (- fy ay))
         (len2 (+ (* dx dx) (* dy dy)))
         (total 0.0d0) (on 0.0d0))
    (declare (type f32 dx dy len2) (type double-float total on))
    (when (<= len2 1.0f-12) (return-from colony-route-fidelity nil))
    (dotimes (j ch)
      (dotimes (i cw)
        (let ((amt (aref (the f32v v) (+ i (* j cw)))))
          (when (> amt 0.0f0)
            (let* ((x (+ ox (* (+ i 0.5f0) cell)))
                   (y (+ oy (* (+ j 0.5f0) cell)))
                   ;; distance from the cell centre to the segment
                   (tt (max 0.0f0
                            (min 1.0f0
                                 (/ (+ (* (- x ax) dx) (* (- y ay) dy)) len2))))
                   (px (+ ax (* tt dx))) (py (+ ay (* tt dy)))
                   (ex (- x px)) (ey (- y py)))
              (declare (type f32 x y tt px py ex ey))
              (incf total (float amt 1.0d0))
              (when (<= (+ (* ex ex) (* ey ey)) (* half-width half-width))
                (incf on (float amt 1.0d0))))))))
    (when (plusp total) (/ on total))))
