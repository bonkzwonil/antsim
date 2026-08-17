;;;; tests/ant.lisp — the ant, the choice function, and the tick.
;;;;
;;;; One of these is a §3.8 acceptance row (HOMING-WITHOUT-TRAIL); the
;;;; rest guard the mechanisms it rests on.  The remaining rows —
;;;; symmetry breaking, shortest path, quality selection — need their own
;;;; bridge scenarios and a calibration pass, and are not here yet.

(in-package #:antsim/test)

(in-suite antsim)

;;; ------------------------------------------------------------- rng

(test rnd-normal-is-standard-normal
  (let ((n 40000) (sum 0.0d0) (sum2 0.0d0))
    (dotimes (i n)
      (let ((z (ant:rnd-normal i 0 0)))
        (incf sum z)
        (incf sum2 (* z z))))
    (let* ((mean (/ sum n))
           (var (- (/ sum2 n) (* mean mean))))
      (is (< (abs mean) 0.02d0) "mean ~,4f, want 0" mean)
      (is (< (abs (- var 1.0d0)) 0.05d0) "variance ~,4f, want 1" var))))

(test rnd-normal-is-a-pure-function
  (dotimes (i 40)
    (let ((a (ant:rnd-normal i 5 1)))
      (ant:rnd-normal 999 999 9)
      (is (= a (ant:rnd-normal i 5 1))))))

;;; ------------------------------------------------------------ angles

(test wrap-angle-lands-in-range
  (dolist (a '(0.0 3.0 -3.0 7.0 -7.0 100.0 -100.0))
    (let ((w (ant:wrap-angle (float a 1.0f0))))
      (is (and (<= w 3.1415928f0) (> w -3.1415928f0))
          "wrap(~a) = ~a is out of range" a w)))
  ;; wrapping must not change the direction it names
  (dolist (a '(0.3 -2.0 5.0 -6.5))
    (let* ((x (float a 1.0f0)) (w (ant:wrap-angle x)))
      (is (< (abs (- (cos x) (cos w))) 1e-4))
      (is (< (abs (- (sin x) (sin w))) 1e-4)))))

(test angle-toward-takes-the-short-way-round
  "The whole point of turning by a weight is that it is gradual; taking
the long way round would make a homing ant orbit its nest."
  ;; from just below +pi to just above -pi is a short hop across the seam
  (let ((r (ant:angle-toward 3.0f0 -3.0f0 0.5f0)))
    (is (> (abs r) 3.0f0) "went the long way: ~a" r))
  (is (< (abs (- (ant:angle-toward 0.0f0 1.0f0 0.5f0) 0.5f0)) 1e-5))
  (is (< (abs (- (ant:angle-toward 0.0f0 1.0f0 0.0f0) 0.0f0)) 1e-5))
  (is (< (abs (- (ant:angle-toward 0.0f0 1.0f0 1.0f0) 1.0f0)) 1e-5)))

;;; ------------------------------------------- the choice function

(test choice-function-is-uniform-without-pheromone
  "§3.5: with no pheromone every weight is k^n, so the rule degenerates
*exactly* into the correlated random walk.  This is what makes
'exploring' and 'trail-following' one behaviour rather than two, and it
only holds if the three options come out equally likely."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 32))
         (c (ant:add-colony w :nest-x 0.2f0 :nest-y 0.2f0))
         (left 0) (straight 0) (right 0))
    (dotimes (k 6000)
      (let ((d (ant:choose-turn w (ant:colony-id c) k 0 0.2f0 0.2f0 0.0f0)))
        (cond ((< d 0.0f0) (incf left))
              ((> d 0.0f0) (incf right))
              (t (incf straight)))))
    (dolist (count (list left straight right))
      (is (< (abs (- count 2000)) 150)
          "~a/~a/~a is not uniform" left straight right))))

(test choice-function-amplifies-a-difference
  "n > 1 is the entire model (§3.3): a small concentration difference has
to produce a *large* probability difference.  With n = 2 and one arm at
2k, the preference must be well past the linear 2:1."
  (let* ((ant:*trail-lane-offset* 0.0f0) ; isolate the choice function
         (w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 32))
         (c (ant:add-colony w :nest-x 0.2f0 :nest-y 0.2f0))
         (f (ant:colony-field c))
         (right 0) (n 6000))
    ;; lay a patch on the right-hand sensor only
    (let* ((h 0.0f0) (hr ant:*sensor-spread*)
           (sx (+ 0.2f0 (* ant:*sensor-offset* (cos hr))))
           (sy (+ 0.2f0 (* ant:*sensor-offset* (sin hr)))))
      (declare (ignore h))
      (ant:field-deposit! f sx sy ant:*choice-k*)
      (ant:field-step! f 0.0f0))
    (dotimes (k n)
      (when (> (ant:choose-turn w (ant:colony-id c) k 0 0.2f0 0.2f0 0.0f0) 0.0f0)
        (incf right)))
    ;; weights are k^2 : k^2 : (2k)^2 = 1 : 1 : 4, so 4/6 = 66.7%
    (let ((frac (/ (float right) n)))
      (is (> frac 0.60) "right-arm share ~,3f, want about 0.667" frac)
      (is (< frac 0.73) "right-arm share ~,3f, want about 0.667" frac))))

(test choice-function-with-n-1-does-not-select
  "§3.8's control row, at the level of the function itself: set n = 1 and
a doubled concentration must produce only a *linear* preference.  If this
ever shows amplification, the selection seen elsewhere is coming from
something other than the choice function."
  (let* ((ant:*choice-n* 1.0f0)
         (ant:*trail-lane-offset* 0.0f0) ; isolate the choice function
         (w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 32))
         (c (ant:add-colony w :nest-x 0.2f0 :nest-y 0.2f0))
         (f (ant:colony-field c))
         (right 0) (n 6000))
    (let* ((hr ant:*sensor-spread*)
           (sx (+ 0.2f0 (* ant:*sensor-offset* (cos hr))))
           (sy (+ 0.2f0 (* ant:*sensor-offset* (sin hr)))))
      (ant:field-deposit! f sx sy ant:*choice-k*)
      (ant:field-step! f 0.0f0))
    (dotimes (k n)
      (when (> (ant:choose-turn w (ant:colony-id c) k 0 0.2f0 0.2f0 0.0f0) 0.0f0)
        (incf right)))
    ;; weights k : k : 2k, so 2/4 = 50%
    (let ((frac (/ (float right) n)))
      (is (and (> frac 0.45) (< frac 0.55))
          "with n = 1 the right-arm share is ~,3f, want about 0.5" frac))))

;;; ------------------------------------------------- §3.8 acceptance

(test homing-without-trail
  "§3.8 acceptance row: a single ant in a virgin arena, with no
pheromone anywhere and no nestmates, must find its way back to the nest
by path integration alone.

This is the row that everything else depends on.  Without a working home
vector no ant that finds food in unmarked ground can get home, so the
first trail can never be laid and the whole recruitment cascade has no
seed (§3.4)."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 16))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :nest-r 0.02f0
                              :stock 1.0f6))
         (a (ant:world-ants w)))
    (ant:world-seed-population! w c 1)
    (let ((b (ant:world-bodies w)))
      ;; walk it away from the nest
      (setf (aref (ant:ants-state a) 0) ant:+ant-outbound+)
      (dotimes (k 3000)
        (setf (aref (ant:ants-energy a) 0) 1.0f0)   ; isolate navigation
        (ant:world-step! w))
      (let* ((bi (aref (ant:ants-body a) 0))
             (dx (- (aref (ant:bodies-x b) bi) 0.5f0))
             (dy (- (aref (ant:bodies-y b) bi) 0.5f0))
             (out (sqrt (+ (* dx dx) (* dy dy)))))
        (is (> out 0.10f0) "the ant only reached ~,3f m; nothing to home from" out)
        ;; Now send it home, and stop the moment it arrives.  Running a
        ;; fixed number of ticks and checking the state at the end does
        ;; not test this: an ant that gets home goes IN-NEST, rests, and
        ;; then sets out again, so a late enough sample finds it far away
        ;; for the most ordinary reason.
        (let ((arrived nil))
          (setf (aref (ant:ants-state a) 0) ant:+ant-returning+)
          (dotimes (k 6000)
            (setf (aref (ant:ants-energy a) 0) 1.0f0)
            (ant:world-step! w)
            (when (= ant:+ant-in-nest+ (aref (ant:ants-state a) 0))
              (setf arrived k)
              (return)))
          (is-true arrived
                   "never arrived: ~,3f m from the nest, home vector (~,3f ~,3f)"
                   (let ((ddx (- (aref (ant:bodies-x b) bi) 0.5f0))
                         (ddy (- (aref (ant:bodies-y b) bi) 0.5f0)))
                     (sqrt (+ (* ddx ddx) (* ddy ddy))))
                   (aref (ant:ants-hvx a) 0) (aref (ant:ants-hvy a) 0))
          ;; and it must get there roughly directly, not by luck
          (when arrived
            (is (< arrived (round (* 4 (/ out 0.001f0))))
                "took ~d ticks to cover ~,3f m; that is not homing" arrived out)))))))

(defun %walled-homing-run (steps &key (ticks 20000) (detour 0))
  "Put one laden ant above a wall, its nest below, and let it try to get
home.  Returns the tick it arrived on, or NIL.

The wall does not span the arena: there is a way round its left end, so
the only question the run asks is whether the ant finds it.

DETOUR is Layer 1's commitment window and defaults to *off* here, so this
fixture keeps measuring the antennal scan it was written for.  There are
now two mechanisms that can get an ant round a wall and they have to be
measurable apart — with the latch on, the scan's own control run
succeeds, which would quietly turn this regression test into a test of
nothing.  A-COMMITTED-ANT-ROUNDS-A-WALL-WITHOUT-THE-SCAN is the other
half."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 16))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.2f0 :nest-r 0.02f0
                              :stock 1.0f6))
         (a (ant:world-ants w))
         (ant:*detour-ticks* detour)
         (ant:*homing-scan-steps* steps))
    (ant:add-obstacle w '(0.30 0.40 0.90 0.40 0.90 0.45 0.30 0.45))
    (ant:world-seed-population! w c 1)
    (let* ((b (ant:world-bodies w))
           (bi (aref (ant:ants-body a) 0)))
      (setf (aref (ant:bodies-x b) bi) 0.5f0
            (aref (ant:bodies-y b) bi) 0.6f0
            ;; nest straight down, i.e. straight through the wall
            (aref (ant:ants-hvx a) 0) 0.0f0
            (aref (ant:ants-hvy a) 0) -0.4f0
            (aref (ant:ants-crop a) 0) 1.0f0
            (aref (ant:ants-load-quality a) 0) 1.0f0
            (aref (ant:ants-state a) 0) ant:+ant-returning+)
      (dotimes (k ticks)
        (setf (aref (ant:ants-energy a) 0) 1.0f0) ; isolate navigation
        (ant:world-step! w)
        (when (= ant:+ant-in-nest+ (aref (ant:ants-state a) 0))
          (return k))))))

(test a-laden-ant-gets-round-a-wall
  "§3.2/§3.4 regression, and the most expensive bug this model has had.

The home vector points *through* obstacles.  For a long time the ant
followed it there: it pressed against the surface, the collision pass
removed only the component into the wall so it slid along the face, and
because deposition counts attempted motion it marked the face while
sliding.  The mark recruited others, so a route grew along the obstacle
with dead ants on it, and colonies starved beside full sources.

Two full suites passed throughout.  Nothing here is subtle to watch and
nothing was measurable to assert, which is exactly why this test exists:
one ant, one wall, does it get home.

The scan disabled is asserted too.  A regression test for a navigation
rule is worth very little if it also passes without the rule — and this
one very nearly did, twice, through two different failures that each
left the ant walking millimetres per thousand ticks."
  (let ((with (%walled-homing-run 12))
        (without (%walled-homing-run 0)))
    (is-true with
             "never got round the wall in 20000 ticks with the scan on")
    (is-false without
              "arrived at tick ~a with the scan off, so this test does not
test the scan" without)
    (when with
      ;; It has to walk about 0.4 m round the end of the wall and back,
      ;; so a few thousand ticks is the honest bar; the point is that it
      ;; is a journey and not a wait.
      (is (< with 6000) "took ~d ticks, which is loitering, not walking"
          with))))

;;; **What Layer 1 does not do, recorded because a test once claimed it
;;; did.**
;;;
;;; There was a test here asserting that the detour latch alone gets a
;;; laden ant round a wall with the antennal scan switched off.  It
;;; passed, and it was asserting a bug.
;;;
;;; The latch suppresses the homing urge, and the first version re-armed
;;; itself every window — because a latched ant makes no homeward
;;; progress, which is exactly the evidence the detour test looks for.  So
;;; homing was off *permanently*, the ant fell back on the correlated
;;; random walk, and a random walk does eventually find its way round a
;;; wall in 20 000 ticks.  What the test measured was an ant that had
;;; stopped trying to go home at all.
;;;
;;; The same runaway in a colony is ants drifting to corners in furballs,
;;; laying trail as they went, with full sources untouched and the larder
;;; emptying — all of which was reported from the window and none of which
;;; showed in delivery aggregates, because the ants that had not yet been
;;; caught were still feeding the nest.
;;;
;;; With the feedback removed the latch is a much smaller thing: it buys
;;; one bounded window of not-homing, which is enough to break the
;;; step-out-and-turn-back oscillation but not enough to navigate an
;;; obstacle.  Doing that properly is Layer 2 — remembered corners — which
;;; is not built.  A-LADEN-ANT-GETS-ROUND-A-WALL keeps the latch off for
;;; the same reason it always did: it is a test of the antennal scan.

(defparameter +uturn-run-ticks+ 4000)

(defun %trail-departure-tick (lost seed)
  "Walk one outbound ant along a short trail that stops dead, and return
the tick it first gets 2 cm past the end — or +UTURN-RUN-TICKS+ if it
never does.

The trail runs west to east and ends at x = 0.40 with open ground
beyond, so an ant following it eastward walks off the end.  Nothing
stops it leaving; the question is how long it stays."
  (let* ((ant:*trail-lost-threshold* lost)
         ;; Lane offset off, and the reason is this fixture rather than
         ;; the rule.  The trail below is laid with FIELD-DEPOSIT! at
         ;; single cells, so it is one cell — 5 mm — wide, where a real
         ;; trail is a row of 3 cm packets.  A lane preference of 8 mm
         ;; therefore puts the ant entirely beside this trail rather than
         ;; across its width, and what would be measured is the fixture's
         ;; thinness and not the U-turn edge this test is about.
         ;;
         ;; The interaction is real at full width too and is recorded on
         ;; *trail-lane-offset*: ants spread across a road leave it
         ;; sooner, which is most of that parameter's cost in food.
         (ant:*trail-lane-offset* 0.0f0)
         (w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 16
                            :seed seed))
         (c (ant:add-colony w :nest-x 0.1f0 :nest-y 0.5f0 :nest-r 0.02f0
                              :stock 1.0f6))
         (a (ant:world-ants w))
         (f (ant:colony-field c)))
    (ant:world-seed-population! w c 1)
    (loop for x from 0.20f0 below 0.40f0 by 0.005f0
          do (ant:field-deposit! f x 0.5f0 300.0f0))
    (ant:field-step! f)                 ; deposits become concentration
    (let* ((b (ant:world-bodies w))
           (bi (aref (ant:ants-body a) 0)))
      (setf (aref (ant:bodies-x b) bi) 0.30f0
            (aref (ant:bodies-y b) bi) 0.5f0
            (aref (ant:ants-heading a) 0) 0.0f0   ; walking east, along it
            (aref (ant:ants-crop a) 0) 0.0f0
            (aref (ant:ants-state a) 0) ant:+ant-outbound+)
      (or (dotimes (k +uturn-run-ticks+)
            (setf (aref (ant:ants-energy a) 0) 1.0f0) ; isolate navigation
            (ant:world-step! w)
            (when (> (aref (ant:bodies-x b) bi) 0.42f0)
              (return k)))
          +uturn-run-ticks+))))

(test an-ant-that-loses-a-trail-turns-round
  "§3.2: an ant following a trail that runs out turns about and casts
rather than carrying on, and the point of it is that trails hold their
ants — so that is what is asserted.

Not the about-face itself, which would be testing that the line of code
that adds pi adds pi.  The claim worth defending is the consequence: an
ant that U-turns stays with a trail markedly longer than one that walks
off the end and keeps going.

Summed over seeds rather than judged per seed.  A single ant on a single
seed leaves early or late for reasons that have nothing to do with this
rule — measured, one seed is three times *worse* with U-turns and
another never leaves at all — and reading either of those alone would be
reading noise."
  (let ((with 0) (without 0))
    (dolist (seed '(1 2 3 4 5 6))
      (incf with (%trail-departure-tick 0.15f0 seed))
      (incf without (%trail-departure-tick 0.0f0 seed)))
    (is (> with (* 3/2 without))
        "stayed ~d ticks with U-turns against ~d without, over six seeds; ~
the trail is not holding its ants" with without)))

(test path-integration-tracks-actual-displacement
  "Regression, and an expensive one to have found.  The home vector must
close over where the ant *ended up*, not over the steps it meant to
take.  Walking into the arena boundary is the cheap way to tell the two
apart: the ant does not move, so a correct integrator accumulates
nothing."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 16))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :stock 1.0f6))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:world-seed-population! w c 1)
    (let ((bi (aref (ant:ants-body a) 0)))
      ;; put it on the left wall, pointing into it, and hold it there
      (setf (aref (ant:bodies-x b) bi) 0.0f0
            (aref (ant:bodies-y b) bi) 0.5f0
            (aref (ant:ants-hvx a) 0) 0.5f0
            (aref (ant:ants-hvy a) 0) 0.0f0
            (aref (ant:ants-state a) 0) ant:+ant-outbound+)
      (dotimes (k 400)
        (setf (aref (ant:ants-energy a) 0) 1.0f0
              (aref (ant:ants-heading a) 0) 3.1415927f0)  ; due -x
        (ant:world-step! w))
      ;; it cannot have gone left, so the home vector must still point right
      (is (< (abs (- (aref (ant:bodies-x b) bi) 0.0f0)) 0.02f0))
      (is (> (aref (ant:ants-hvx a) 0) 0.3f0)
          "home vector wound up to ~,3f while the ant walked on the spot"
          (aref (ant:ants-hvx a) 0)))))

(test displaced-nest-ant-still-knows-the-way-home
  "Regression.  An ant does not depart from the middle of its nest: it is
scattered across the disc at birth, it walks in from wherever it arrived,
and until §3.11 exempted resting ants from ant-ant contact the crowd at a
busy nest shoved it as well.  Path integration records all of that.

Departure used to zero the home vector — which told the ant that wherever
it happened to be standing *was* home.  It would forage, return to that
false origin, read a home vector of zero and sit there with a full crop it
could not unload.

Reported from the live window, where a stuck ant is obvious.  No
aggregate — population, stock, trail total — showed anything wrong.

The age is set explicitly because foraging has a maturity gate (§3.10)
and a callow ant will not leave at all; that is a different rule with a
test of its own, and leaving it to chance here would make this one
flaky."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 32))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :nest-r 0.02f0
                              :stock 1.0f6))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:world-seed-population! w c 1)
    (let ((bi (aref (ant:ants-body a) 0)))
      ;; shove the resting ant well clear of the nest, exactly as a crowd
      ;; would, and let path integration see the displacement
      (setf (aref (ant:ants-state a) 0) ant:+ant-in-nest+
            (aref (ant:ants-hvx a) 0) 0.0f0
            (aref (ant:ants-hvy a) 0) 0.0f0)
      (setf (aref (ant:bodies-x b) bi) 0.20f0
            (aref (ant:bodies-y b) bi) 0.20f0)
      ;; old enough to forage — see the docstring
      (setf (aref (ant:ants-age a) 0) (* 10 ant:*forager-maturity-ticks*))
      ;; force it out of the nest
      (let ((ant:*leave-probability* 1.0f0))
        (setf (aref (ant:ants-energy a) 0) 1.0f0)
        (ant:world-step! w))
      (is (= ant:+ant-outbound+ (aref (ant:ants-state a) 0)))
      ;; it must believe home is back at the nest, not under its feet
      (let* ((hx (aref (ant:ants-hvx a) 0))
             (hy (aref (ant:ants-hvy a) 0))
             (len (sqrt (+ (* hx hx) (* hy hy)))))
        (is (> len 0.2f0)
            "home vector is ~,3f m long; the ant thinks it is standing on ~
             the nest while 0.42 m away from it" len)
        ;; and it must point the right way
        (is (> hx 0.0f0) "home vector points away from the nest in x")
        (is (> hy 0.0f0) "home vector points away from the nest in y")))))

(test an-exhausted-source-stops-being-a-source
  "Reported from the window: a stripped pile left a small dot sitting in
the arena for the rest of the run.

At zero amount a source's radius is zero, but a zero-radius body is still
a *body* — it keeps its slot and the renderer still puts a point where
the pile was, which reads as a source that is somehow still there.

A renewing source must survive the same test, because at zero it is empty
*now* and will refill on a later colony tick.  Removing it would delete a
scenario's feature rather than tidy a leftover, and the two cases look
identical at the moment the amount hits zero."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 2000
                            :seed 5))
         (c (ant:add-colony w :nest-x 0.2f0 :nest-y 0.2f0 :nest-r 0.02f0
                              :stock 500.0f0))
         (f (ant:add-food w 0.25f0 0.28f0 0.01f0 60.0f0))
         (bi (ant:food-body f))
         (b (ant:world-bodies w)))
    (ant:world-seed-population! w c 150)
    (is (= 1 (length (ant:world-foods w))))
    (loop repeat 40 until (ant:food-empty-p f)
          do (ant:world-run! w 1200))
    (is-true (ant:food-empty-p f) "the colony never stripped the source")
    (ant:world-run! w 5)
    (is (= 0 (length (ant:world-foods w)))
        "an exhausted source is still in the world's food list")
    (is (= ant:+body-free+ (aref (ant:bodies-kind b) bi))
        "an exhausted source still holds a body slot"))
  ;; and the case that must NOT be removed
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 64 :seed 5)))
    (ant:add-food w 0.2f0 0.2f0 0.01f0 0.0f0 :renew 1.0f0)
    (ant:world-run! w 10)
    (is (= 1 (length (ant:world-foods w)))
        "a renewing source was removed while empty; it was going to refill")))

(test food-depletes-and-the-trail-dies
  "§3.8 acceptance row, both halves of it.

*Food depletion*: a source carries an amount, ants take from it, and at
zero it is gone. There is no special case anywhere — the source simply
stops filling crops.

*Trail death*: and then the trail to it decays to background on the
evaporation timescale, with nothing telling it to. That is the whole
point of evaporation being in the model at all (§3.3): it is the only
mechanism by which a colony can forget, and without it a trail to an
exhausted source would persist for ever and the colony would never
re-explore."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 600))
         (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.08f0
                              :capacity 400 :stock 400.0f0))
         ;; small and close, so it is emptied inside a short run
         (f (ant:add-food w 0.20f0 0.26f0 0.03f0 260.0f0 :quality 1.0f0)))
    (ant:world-seed-population! w c 80)
    ;; forage until the source is gone
    (let ((peak 0.0d0))
      (dotimes (i 40)
        (ant:world-run! w 1200)
        (setf peak (max peak (ant:field-total (ant:colony-field c))))
        (when (ant:food-empty-p f) (return)))
      (is-true (ant:food-empty-p f)
               "the source still holds ~,1f after 40 minutes"
               (ant:food-amount f))
      (is (> peak 1000.0d0)
          "no real trail was ever built (peak ~,0f), so trail death is ~
           not being tested" peak)
      ;; nothing removes the trail; only evaporation can
      (ant:world-run! w (* 1200 60))
      (let ((now (ant:field-total (ant:colony-field c))))
        (is (< now (* 0.4d0 peak))
            "trail is ~,0f, down from a peak of ~,0f — less decay than one ~
             hour of evaporation should give" now peak)))))

;;; --------------------------------------------------- foraging urgency

(defun %nest-energies! (w value)
  "Put every resting ant at exactly VALUE energy, so a departure test can
vary one thing at a time."
  (let ((a (ant:world-ants w)))
    (dotimes (i (ant:ants-n a))
      (when (ant:ant-live-p a i)
        (setf (aref (ant:ants-energy a) i) value)))))

(test an-empty-larder-sends-under-fuelled-ants-out
  "The colony must not be able to starve with the door shut.

This is a regression test for a deadlock, and the deadlock was real: a
departure needed energy, energy came from the nest's stock, and the stock
came from departures.  When a source ran dry those three closed into a
ring — every ant came home, dropped below the departure threshold, could
not be fed, and lay in the nest until it died of old age without one of
them ever going out to look.  Measured at the time: 499 ants in the nest,
0 outbound, for the rest of the run.

The pair is the point.  Both colonies hold ants at exactly the same
energy — 0.30, under the well-fed departure threshold — and differ only
in what is in the larder.  So it is not the ants' own reserves doing the
work in either case, and the two runs cannot both be explained by
starvation.

Note what an ant reads here, because it matters that this is not
telepathy: it is fed from the stock while it rests, and being given
nothing is a local fact about its own body.  No ant consults the colony's
food supply, and none of this tells an ant anything about food it has not
visited."
  (flet ((departures (stock ticks)
           (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0
                                     :capacity 400))
                  (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.20f0
                                       :capacity 300 :stock stock)))
             (ant:world-seed-population! w c 60)
             (%nest-energies! w 0.30f0)
             (ant:world-run! w ticks)
             (values (ant:ants-count-state (ant:world-ants w)
                                           ant:+ant-outbound+)
                     c))))
    ;; 60 ticks: short enough that a fed colony cannot climb back over the
    ;; well-fed threshold within the run, so the two cases stay separated
    ;; by the larder alone.
    (multiple-value-bind (hungry hc) (departures 0.0f0 60)
      (multiple-value-bind (fed fc) (departures 400.0f0 60)
        (is (> (ant:colony-forage-urgency hc) 0.9f0)
            "an empty larder should read as maximum urgency, got ~,2f"
            (ant:colony-forage-urgency hc))
        (is (< (ant:colony-forage-urgency fc) 0.1f0)
            "a full larder should read as no urgency, got ~,2f"
            (ant:colony-forage-urgency fc))
        (is (> hungry 20)
            "only ~d of 60 ants left a nest with an empty larder — the ~
             colony is starving indoors" hungry)
        (is (< fed hungry)
            "a fed colony sent out ~d and a starving one ~d; hunger is ~
             not raising the departure rate" fed hungry)))))

(test a-forager-is-spent-before-it-is-saved
  "The bar for giving up must sit *below* the bar for setting out, and
further below the hungrier the colony is (§3.5).

These were one number, on the reasoning that setting out and turning
back are two ends of one decision.  That reasoning has a hole in it, and
the hole cost a colony: an ant leaves when its energy is above the bar,
so an ant that leaves at the margin is *at* the bar — and with one
number it therefore qualified to turn back on its very next tick.
Measured on the double bridge, 560 ants outside the nest, 3 of them
carrying anything, nothing delivered that minute.  The colony was
walking its whole workforce out of the door and straight back in.

Whether to spend a forager is the colony's question and whether the
forager survives is the forager's, and a superorganism does not weight
them equally.

The *mechanism* is what is tested here, bound on explicitly, because it
ships **off**: measured, spending foragers took the population from 626
to 207 and deaths from 23 to 457 with births flat, and once brood
regulation (§3.10) gave the colony a reserve it became unreachable
altogether — urgency never rises to where it fires. The invariant it
rests on is tested at the default too, since that is the part that must
hold however the parameter is set."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 200))
         (rich (ant:add-colony w :nest-x 0.10f0 :nest-y 0.10f0
                                 :stock 400.0f0))
         (poor (ant:add-colony w :nest-x 0.30f0 :nest-y 0.30f0
                                 :stock 0.0f0)))
    (ant:world-seed-population! w rich 40)
    (ant:world-seed-population! w poor 40)
    ;; The invariant, whatever the parameter says: an ant that sets out at
    ;; the margin must not already qualify to turn back.
    (dolist (setting (list ant:*forager-expendability* 1.0f0 0.5f0 0.0f0))
      (let ((ant:*forager-expendability* setting))
        (dolist (c (list rich poor))
          (is (<= (ant:colony-giveup-threshold c)
                  (ant:colony-energy-threshold c))
              "at expendability ~,2f give-up (~,3f) is above departure (~,3f)"
              setting
              (ant:colony-giveup-threshold c)
              (ant:colony-energy-threshold c)))))
    ;; And the mechanism itself, turned on.
    (let ((ant:*forager-expendability* 0.0f0))
      (is (< (ant:colony-giveup-threshold poor)
             (ant:colony-energy-threshold poor))
          "a starving colony's foragers give up at the same bar they left ~
on (~,3f); nothing is being spent"
          (ant:colony-giveup-threshold poor))
      (is (< (ant:colony-giveup-threshold poor)
             (ant:colony-giveup-threshold rich))
          "hunger did not lower the give-up bar: ~,3f against ~,3f"
          (ant:colony-giveup-threshold poor)
          (ant:colony-giveup-threshold rich)))
    ;; At the shipped default the two coincide, which is the old
    ;; behaviour and is recorded here so that changing the default
    ;; changes a test rather than silently changing the model.
    (is (= (ant:colony-giveup-threshold poor)
           (ant:colony-energy-threshold poor))
        "expendability is no longer off by default; if that is intended, ~
this assertion is the place to say so")))

(test an-ant-in-the-field-cannot-read-the-larder
  "§3.5: how deep a forager digs into its reserve is learnt at the nest
door and carried, not looked up while it walks.

The distinction is the difference between a superorganism and a shared
global.  A colony that is fed while this ant is halfway across the arena
must not reach out and change the ant's mind — the only honest way for
it to have learnt anything about the larder is by asking for food while
resting and being told what there was.

Tested by moving the larder underneath an ant that is already out.  Its
resolve must not budge.

Expendability is bound on so that there is a gap to observe at all: with
it off — the shipped default — the give-up bar equals the departure bar
and a stale reading would be indistinguishable from a fresh one.  What is
being tested is the *carrying*, which is true either way."
  (let* ((ant:*forager-expendability* 0.0f0)
         (w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 64))
         (c (ant:add-colony w :nest-x 0.2f0 :nest-y 0.2f0 :stock 0.0f0))
         (a (ant:world-ants w)))
    (ant:world-seed-population! w c 8)
    ;; send one out with a starving larder behind it
    (setf (aref (ant:ants-resolve a) 0) (ant:colony-giveup-threshold c)
          (aref (ant:ants-state a) 0) ant:+ant-outbound+)
    (let ((carried (aref (ant:ants-resolve a) 0)))
      (is (< carried (ant:colony-energy-threshold c))
          "a starving colony should send its foragers out to dig deeper ~
than the departure bar, not the same (~,3f)" carried)
      ;; now fill the larder while it is away
      (setf (ant:colony-stock c) 4000.0f0)
      (is (> (ant:colony-giveup-threshold c) carried)
          "the test is not testing anything: feeding the colony did not ~
move its give-up bar")
      (dotimes (k 200) (ant:world-step! w))
      (is (< (abs (- (aref (ant:ants-resolve a) 0) carried)) 1.0f-6)
          "resolve moved from ~,4f to ~,4f while the ant was in the ~
field; it is reading the colony, not remembering it"
          carried (aref (ant:ants-resolve a) 0)))))

(test hunger-lowers-the-bar-for-setting-out
  "A hungry colony turns itself out of doors: it accepts foragers with
less in reserve, and sends them more often."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 200))
         (full (ant:add-colony w :nest-x 0.10f0 :nest-y 0.10f0
                                 :stock 400.0f0))
         (empty (ant:add-colony w :nest-x 0.30f0 :nest-y 0.30f0
                                  :stock 0.0f0)))
    (ant:world-seed-population! w full 40)
    (ant:world-seed-population! w empty 40)
    (is (< (ant:colony-energy-threshold empty)
           (ant:colony-energy-threshold full))
        "a hungry colony's foragers should push deeper into reserve ~
         (~,3f) than a fed colony's (~,3f)"
        (ant:colony-energy-threshold empty)
        (ant:colony-energy-threshold full))
    (is (> (ant:colony-leave-probability empty)
           (* 2.0f0 (ant:colony-leave-probability full)))
        "hunger barely changed the departure rate: ~,4f vs ~,4f"
        (ant:colony-leave-probability empty)
        (ant:colony-leave-probability full))
    ;; and the fed colony must be left exactly where it was
    (is (< (abs (- (ant:colony-energy-threshold full)
                   ant:*energy-return-threshold*))
           0.02f0)
        "a fed colony's threshold drifted from the calibrated value")))

;;; ---------------------------------------------------- route fidelity

(test an-ant-leaves-the-nest-the-way-it-came-in
  "§3.4 route fidelity, and a regression test for its absence.

Departure used not to set a heading at all.  That is not a neutral
omission: a returning ant steers *at* the nest, so the heading it carries
in points inward, and keeping it sent the ant out through the entrance
and straight on — away from everything it knew.  Measured on an
established trail before the fix, 65% of departures left within 30
degrees of exactly opposite the source and not one left towards it.  It
showed up in the window as ants wandering off with no plan.

Here every resting ant is given the same remembered bearing, so the only
question the test asks is whether departure honours it."
  (let* ((w (ant:make-world :width 0.6f0 :height 0.6f0 :capacity 400))
         (c (ant:add-colony w :nest-x 0.30f0 :nest-y 0.30f0
                              :capacity 300 :stock 900.0f0))
         (target 1.2f0)                     ; the bearing they all "came in" on
         (a (ant:world-ants w))
         (deviations '()))
    (ant:world-seed-population! w c 80)
    (dotimes (i (ant:ants-n a))
      (when (ant:ant-live-p a i)
        (setf (aref (ant:ants-exit a) i) target
              (aref (ant:ants-energy a) i) 1.0f0)))
    ;; step one tick at a time so a departure can be caught at the moment
    ;; it happens — a heading read later has already been turned by the
    ;; walk itself
    (let ((was (make-array (ant:ants-n a) :element-type '(unsigned-byte 8))))
      (dotimes (i (ant:ants-n a))
        (setf (aref was i) (aref (ant:ants-state a) i)))
      (dotimes (tick 600)
        (ant:world-step! w)
        (dotimes (i (length was))
          (when (and (ant:ant-live-p a i)
                     (= (aref was i) ant:+ant-in-nest+)
                     (= (aref (ant:ants-state a) i) ant:+ant-outbound+))
            (push (abs (ant:wrap-angle
                        (- (aref (ant:ants-heading a) i) target)))
                  deviations))
          (setf (aref was i) (aref (ant:ants-state a) i)))))
    (is (> (length deviations) 20)
        "only ~d ants left the nest — nothing to measure"
        (length deviations))
    (let ((mean (/ (reduce #'+ deviations) (max 1 (length deviations)))))
      (is (< mean (* 2.0f0 ant:*nest-exit-scatter*))
          "departures sat ~,2f rad off the remembered bearing on average, ~
           against a scatter of ~,2f — the bearing is not being honoured"
          mean ant:*nest-exit-scatter*)
      ;; and specifically not the old failure, which was the opposite way
      (is (< (count-if (lambda (d) (> d 2.0f0)) deviations)
             (floor (length deviations) 10))
          "~d of ~d departures left more than 115 degrees off the ~
           remembered bearing"
          (count-if (lambda (d) (> d 2.0f0)) deviations)
          (length deviations)))))

(test only-a-paying-trip-overwrites-the-remembered-route
  "A forager that comes home empty keeps the bearing it had.

Otherwise a failed trip would overwrite a good route with a bad one, and
— worse — an ant that has never succeeded would stop exploring, because
its random birth bearing is exactly what makes the naive ants the
colony's explorers."
  (let* ((w (ant:make-world :width 0.6f0 :height 0.6f0 :capacity 200))
         (c (ant:add-colony w :nest-x 0.30f0 :nest-y 0.30f0
                              :capacity 100 :stock 200.0f0))
         (a (ant:world-ants w)))
    ;; no food anywhere, so every trip that ends at home ended empty
    (ant:world-seed-population! w c 40)
    (let ((before (make-array (ant:ants-n a) :element-type 'single-float)))
      (dotimes (i (ant:ants-n a))
        (setf (aref before i) (aref (ant:ants-exit a) i)))
      (ant:world-run! w 6000)
      (let ((changed 0) (checked 0))
        (dotimes (i (length before))
          (when (ant:ant-live-p a i)
            (incf checked)
            (unless (= (aref before i) (aref (ant:ants-exit a) i))
              (incf changed))))
        (is (> checked 10) "no ants survived to check")
        (is (zerop changed)
            "~d of ~d ants rewrote their remembered route without ever ~
             bringing anything home" changed checked)))))

;;; ------------------------------------------------------ determinism

(test a-run-is-reproducible
  "§4.4: two identical worlds stepped the same number of ticks must end
byte-identical.  This is the test that catches a stateful RNG, an
order-dependent collision pass, or a deposit applied in place."
  (flet ((snapshot (seed)
           (let* ((w (ant:make-world :width 0.5f0 :height 0.5f0
                                     :capacity 600 :seed seed))
                  (c (ant:add-colony w :nest-x 0.25f0 :nest-y 0.10f0
                                       :stock 500.0f0)))
             (ant:add-food w 0.25f0 0.30f0 0.03f0 5000.0f0 :quality 1.0f0)
             (ant:world-seed-population! w c 40)
             (ant:world-run! w 1500)
             (list (copy-seq (ant:bodies-x (ant:world-bodies w)))
                   (copy-seq (ant:bodies-y (ant:world-bodies w)))
                   (copy-seq (ant:ants-energy (ant:world-ants w)))
                   (copy-seq (ant:ants-hvx (ant:world-ants w)))
                   (ant:colony-population c)
                   (ant:field-total (ant:colony-field c))))))
    (let ((a (snapshot ant:+default-seed+))
          (b (snapshot ant:+default-seed+)))
      (is (equalp a b) "two identical runs diverged"))
    ;; and a different seed must actually change the run
    (let ((a (snapshot ant:+default-seed+))
          (c (snapshot 12345)))
      (is (not (equalp a c)) "changing the seed changed nothing"))))

;;; --------------------------------------------------- individual pace
;;;
;;; A lifelong trait, like handedness, and it has the same three things to
;;; prove: that it is fixed per individual, that it is centred so the
;;; colony's average is the number §3.1 calibrated, and that it has an off
;;; position which restores the previous model exactly.

(test ant-pace-is-a-fixed-property-of-the-individual
  (let ((seed 42))
    (dotimes (id 200)
      (let ((p (ant:ant-pace id seed)))
        ;; no tick goes in, so nothing can move it
        (is (= p (ant:ant-pace id seed)))
        (is (<= (- 1.0f0 ant:*speed-spread*) p (+ 1.0f0 ant:*speed-spread*))
            "ant ~d walks at ~,4f, outside +/-~,2f" id p ant:*speed-spread*)))
    ;; and different ants really do differ
    (let ((paces (loop for id below 200 collect (ant:ant-pace id seed))))
      (is (> (length (remove-duplicates paces)) 190)
          "only ~d distinct paces in 200 ants" (length (remove-duplicates paces)))
      (is (> (- (reduce #'max paces) (reduce #'min paces))
             (* 1.8f0 ant:*speed-spread*))
          "the paces span only ~,4f of a ~,4f range"
          (- (reduce #'max paces) (reduce #'min paces))
          (* 2.0f0 ant:*speed-spread*)))))

(test ant-pace-is-centred-on-the-calibrated-speed
  "The colony's mean walking speed must still be *WALK-SPEED*.  A spread
that drifted off centre would quietly recalibrate §3.1 — every distance
in the model is a time to walk it — and would do so invisibly, because
every individual would still look reasonable."
  (let* ((paces (loop for id below 20000 collect (ant:ant-pace id 7)))
         (mean (/ (reduce #'+ paces) (length paces))))
    (is (< (abs (- mean 1.0f0)) 0.005f0)
        "mean pace ~,5f, want 1" mean)))

(test ant-pace-is-not-correlated-with-handedness
  "Its own stream (§4.4).  Drawing both from one would make every
left-handed ant fast, which is a rule nobody wrote and nobody could find."
  (let ((left-sum 0.0f0) (left-n 0) (right-sum 0.0f0) (right-n 0))
    (dotimes (id 20000)
      (if (minusp (ant:ant-handedness id 3))
          (progn (incf left-sum (ant:ant-pace id 3)) (incf left-n))
          (progn (incf right-sum (ant:ant-pace id 3)) (incf right-n))))
    (let ((l (/ left-sum left-n)) (r (/ right-sum right-n)))
      (is (< (abs (- l r)) 0.006f0)
          "left-handed ants average ~,5f and right-handed ~,5f" l r))))

(test speed-spread-has-an-exact-off-position
  "Zero must restore the previous model *bit for bit*, not nearly: the
pace multiplies the step, so anything other than exactly 1 changes every
trajectory and with it every published figure."
  (let ((ant:*speed-spread* 0.0f0))
    (dotimes (id 500)
      (is (= 1.0f0 (ant:ant-pace id 11))))))

(test individual-ants-walk-at-different-speeds
  "The behavioural end of it: same heading, same state, same tick,
different ground covered.  Asserted on the ants rather than on the
function, because the function being right and never being *called* looks
identical from outside."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 200))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.02f0 :nest-r 0.01f0
                              :capacity 200 :stock 500.0f0))
         (a (ant:world-ants w))
         (b (ant:world-bodies w))
         (n 40))
    (dotimes (i n) (ant:spawn-ant w c))
    ;; Spread them across open ground, all walking the same way, far
    ;; enough apart that the non-overlap rule has nothing to say.
    (dotimes (i n)
      (let ((bi (aref (ant:ants-body a) i)))
        (setf (aref (ant:bodies-x b) bi) (+ 0.02f0 (* i 0.024f0))
              (aref (ant:bodies-y b) bi) 0.5f0
              (aref (ant:bodies-kind b) bi) ant:+body-ant+
              (aref (ant:ants-state a) i) ant:+ant-outbound+
              (aref (ant:ants-heading a) i) 0.0f0
              (aref (ant:ants-crop a) i) 0.0f0)))
    (let ((before (loop for i below n
                        collect (aref (ant:bodies-x b)
                                      (aref (ant:ants-body a) i)))))
      (ant:world-step! w)
      (let* ((moved (loop for i below n
                          for x0 in before
                          collect (abs (- (aref (ant:bodies-x b)
                                                (aref (ant:ants-body a) i))
                                          x0))))
             (lo (reduce #'min moved))
             (hi (reduce #'max moved)))
        ;; Heading noise is on top of this, so the bar is that the spread
        ;; is *there* rather than that it is exactly 20%.
        (is (> (/ hi (max lo 1.0f-9)) 1.10f0)
            "fastest ant covered ~,6f and slowest ~,6f — one speed for all"
            hi lo)))))

;;; ------------------------------------------------------ the gait (§5.2)
;;;
;;; The stride phase is display state and the only piece of it the model
;;; carries, so it is worth being exact about what it promises: it is a
;;; *distance*, not a clock.  That promise is the whole of the walk cue —
;;; a foot planted in world space is only planted if the phase it is
;;; derived from advanced by exactly the ground the ant covered — and
;;; nothing in the renderer can check it, because a frame cannot see how
;;; far anything moved.

(test gait-phase-advances-with-distance-not-with-time
  "Two ants, same number of ticks, different distances covered: the
phase must follow the distance.  Tie it to the clock instead and every
ant moonwalks, which is precisely the failure §5.2 exists to avoid."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 40))
         (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.20f0 :stock 100.0f0))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:spawn-ant w c)
    (setf (aref (ant:ants-gait a) 0) 0.0f0)
    (let ((bi (aref (ant:ants-body a) 0)))
      ;; Walk it by hand, so the distance is known exactly rather than
      ;; whatever the walk happened to produce.
      (flet ((move (dx)
               (setf (aref (ant:ants-px a) 0) (aref (ant:bodies-x b) bi)
                     (aref (ant:ants-py a) 0) (aref (ant:bodies-y b) bi))
               (incf (aref (ant:bodies-x b) bi) dx)
               (ant:path-integration-step! w)))
        (let ((s ant:*gait-stride*))
          ;; a quarter of a stride is a quarter of a cycle
          (move (* 0.25f0 s))
          (is (< (abs (- (aref (ant:ants-gait a) 0) 0.25f0)) 1.0f-4)
              "phase ~,4f after a quarter stride" (aref (ant:ants-gait a) 0))
          ;; standing still advances nothing, however many ticks pass
          (dotimes (i 20) (move 0.0f0))
          (is (< (abs (- (aref (ant:ants-gait a) 0) 0.25f0)) 1.0f-4)
              "phase moved while the ant stood still: ~,4f"
              (aref (ant:ants-gait a) 0))
          ;; and it wraps rather than growing without bound
          (dotimes (i 40) (move (* 0.37f0 s)))
          (let ((p (aref (ant:ants-gait a) 0)))
            (is (and (<= 0.0f0 p) (< p 1.0f0)) "phase ~,4f left [0,1)" p)))))))

(test gait-phase-follows-the-ground-covered-not-the-step-attempted
  "The other half of the same promise, and the one that matters in a
jam: an ant shoved back to where it started has not walked, and its feet
must say so.  Deposition takes the opposite view of the same tick (§3.3)
and both are right — which is exactly why this is worth pinning down."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 40))
         (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.20f0 :stock 100.0f0))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:spawn-ant w c)
    (setf (aref (ant:ants-gait a) 0) 0.0f0)
    (let* ((bi (aref (ant:ants-body a) 0))
           (x0 (aref (ant:bodies-x b) bi)))
      ;; the tick started here, the ant tried to move, and the solver put
      ;; it back: net displacement zero
      (setf (aref (ant:ants-px a) 0) x0
            (aref (ant:ants-py a) 0) (aref (ant:bodies-y b) bi)
            (aref (ant:bodies-x b) bi) x0)
      (ant:path-integration-step! w)
      (is (= 0.0f0 (aref (ant:ants-gait a) 0))
          "a stalled ant's legs kept moving: ~,4f"
          (aref (ant:ants-gait a) 0)))))

(test a-cohort-does-not-step-in-unison
  "Newborns get their phase from their id (§5.2).  Zero would work and
looks wrong: a batch of workers emerging together would march in step,
which is a thing ants conspicuously do not do and the eye catches at
once."
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 200))
         (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.20f0 :stock 500.0f0))
         (a (ant:world-ants w)))
    (dotimes (i 60) (ant:spawn-ant w c))
    (let ((phases (loop for i below 60 collect (aref (ant:ants-gait a) i))))
      (is (every (lambda (p) (and (<= 0.0f0 p) (< p 1.0f0))) phases))
      ;; spread over the cycle, not clustered at one point
      (is (> (- (reduce #'max phases) (reduce #'min phases)) 0.8f0)
          "phases span only ~,3f of the cycle"
          (- (reduce #'max phases) (reduce #'min phases)))
      (is (> (length (remove-duplicates phases)) 50)
          "only ~d distinct phases in 60 ants"
          (length (remove-duplicates phases))))))

(test a-colony-with-no-food-dies-out
  "§3.8 acceptance row: a nest placed out of foraging range starves.
Stock falls, births stop, the population decays.  Extinction is a
legitimate run outcome, not a bug (§3.10) — and this is also the test
that a colony cannot live on nothing."
  (let* ((w (ant:make-world :width 0.5f0 :height 0.5f0 :capacity 400))
         (c (ant:add-colony w :nest-x 0.25f0 :nest-y 0.25f0
                              :capacity 300 :stock 20.0f0)))
    ;; no food anywhere in the world
    (ant:world-seed-population! w c 60)
    (ant:world-run! w 40000)
    (is (= 0.0f0 (ant:colony-stock c)) "stock ~,2f" (ant:colony-stock c))
    (is (< (ant:colony-population c) 60)
        "population ~d did not fall" (ant:colony-population c))
    (is (plusp (ant:colony-died c)))))

;;; ---------------------------------------- Layer 0: the stall window
;;;
;;; An ant carrying a home vector already holds everything it needs to
;;; notice it is getting nowhere, and the model used to throw half of it
;;; away — the vector's length was computed every tick and read only for a
;;; validity check.  Snapshot it, count the walking between snapshots, and
;;; the same two numbers give three readings:
;;;
;;;     L  >=  |h - h0|  >=  |h0| - |h|
;;;
;;; The two gaps are different diagnoses and the tests below keep them
;;; apart, because the cheap mistake is to assume one stands in for the
;;; other.  A pinned ant barely displaces, so a metres-denominated test
;;; crawls on exactly the case that most needs catching; a detouring ant
;;; displaces perfectly well and simply does not get home.

(defun %stall-once (&key (state ant:+ant-returning+)
                         (h0 '(0.4f0 0.0f0)) (h '(0.4f0 0.0f0))
                         (walked 0.0f0))
  "Contrive one ant's window, close it, and report what it concluded.

A unit test on the arithmetic rather than a run, deliberately: the three
readings are a claim about two snapshots, and driving an ant into a real
corner to produce them would test the corner as much as the rule.
Returns (values cast stalled)."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 8))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :stock 1.0f6))
         (a (ant:world-ants w)))
    (ant:world-seed-population! w c 1)
    (setf (aref (ant:ants-state a) 0) state
          (aref (ant:ants-h0x a) 0) (first h0)
          (aref (ant:ants-h0y a) 0) (second h0)
          (aref (ant:ants-hvx a) 0) (first h)
          (aref (ant:ants-hvy a) 0) (second h)
          (aref (ant:ants-walked a) 0) walked
          (aref (ant:ants-window a) 0) (1- ant:*stall-window*)
          (aref (ant:ants-cast a) 0) 0
          (aref (ant:ants-stalled a) 0) 0.0f0)
    (ant:stall-step! w)
    (values (aref (ant:ants-cast a) 0)
            (aref (ant:ants-stalled a) 0))))

(test the-two-gaps-are-different-diagnoses
  "L - |h-h0| is walking that went nowhere; |h-h0| - (|h0|-|h|) is travel
that went somewhere other than home.  An ant can have either without the
other, and if the implementation ever conflates them one of these fails."
  ;; Walked 20 cm, got 1 cm: pinned, and not detouring — what little
  ;; ground it made was straight at the nest.
  (multiple-value-bind (cast stalled)
      (%stall-once :h0 '(0.40f0 0.0f0) :h '(0.39f0 0.0f0) :walked 0.20f0)
    (is (plusp cast) "walked 20 cm for 1 cm of ground and did not notice")
    (is (zerop stalled) "a pinned ant must not book a detour: ~,4f" stalled))
  ;; Walked 10 cm and displaced all of it, but sideways: the range home is
  ;; unchanged, so every centimetre was a detour and none of it a stall.
  (multiple-value-bind (cast stalled)
      (%stall-once :h0 '(0.40f0 0.0f0) :h '(0.40f0 0.10f0) :walked 0.103f0)
    (is (zerop cast) "an ant that covered its ground is not pinned")
    (is (> stalled 0.05f0)
        "walked 10 cm across the bearing home and booked ~,4f" stalled))
  ;; And an ant driving straight home is neither.
  (multiple-value-bind (cast stalled)
      (%stall-once :h0 '(0.40f0 0.0f0) :h '(0.30f0 0.0f0) :walked 0.102f0)
    (is (zerop cast))
    (is (zerop stalled) "a good trip booked a stall of ~,4f" stalled)))

(test the-detour-test-never-fires-on-an-outbound-ant
  "The one way this rule could be actively harmful.

An outbound ant is *supposed* to walk away from the nest, so its
homeward progress is negative by design and the detour gap is large on
every successful trip.  Measured against it, the first thing the colony
would write off is the route to the food."
  (multiple-value-bind (cast stalled)
      (%stall-once :state ant:+ant-outbound+
                   :h0 '(0.10f0 0.0f0) :h '(0.40f0 0.0f0) :walked 0.31f0)
    (declare (ignore cast))
    (is (zerop stalled)
        "an outbound ant walking 30 cm away from home booked ~,4f" stalled))
  ;; but it is still pinned if it is pinned — being wedged has nothing to
  ;; do with which way the ant is trying to go
  (multiple-value-bind (cast stalled)
      (%stall-once :state ant:+ant-outbound+
                   :h0 '(0.40f0 0.0f0) :h '(0.40f0 0.0f0) :walked 0.20f0)
    (declare (ignore stalled))
    (is (plusp cast) "a wedged outbound ant must still notice")))

(test a-good-window-clears-the-evidence
  "The stall is evidence about ground the ant is still on.  An ant that
escapes a pocket and starts making way must not carry the old verdict
for the rest of the trip."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 8))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :stock 1.0f6))
         (a (ant:world-ants w)))
    (ant:world-seed-population! w c 1)
    (flet ((close-window (h0 h walked)
             (setf (aref (ant:ants-state a) 0) ant:+ant-returning+
                   (aref (ant:ants-h0x a) 0) (first h0)
                   (aref (ant:ants-h0y a) 0) (second h0)
                   (aref (ant:ants-hvx a) 0) (first h)
                   (aref (ant:ants-hvy a) 0) (second h)
                   (aref (ant:ants-walked a) 0) walked
                   (aref (ant:ants-window a) 0) (1- ant:*stall-window*))
             (ant:stall-step! w)))
      ;; two bad windows accumulate
      (close-window '(0.40f0 0.0f0) '(0.40f0 0.10f0) 0.103f0)
      (let ((one (aref (ant:ants-stalled a) 0)))
        (close-window '(0.40f0 0.10f0) '(0.40f0 0.20f0) 0.103f0)
        (is (> (aref (ant:ants-stalled a) 0) one)
            "a second bad window did not add to the first"))
      ;; and one good one wipes the slate
      (close-window '(0.40f0 0.0f0) '(0.30f0 0.0f0) 0.102f0)
      (is (zerop (aref (ant:ants-stalled a) 0))
          "made 10 cm of ground and still carries ~,4f"
          (aref (ant:ants-stalled a) 0)))))

(test a-resting-ant-carries-no-stall
  "A window is a statement about a stretch of walking.  An ant that has
stopped walking has no such stretch, and must not be able to accumulate
one over the minutes it spends in the nest and then act on it the moment
it sets out."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 8))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :stock 1.0f6))
         (a (ant:world-ants w)))
    (ant:world-seed-population! w c 1)
    (setf (aref (ant:ants-state a) 0) ant:+ant-in-nest+
          (aref (ant:ants-stalled a) 0) 0.9f0
          (aref (ant:ants-walked a) 0) 5.0f0
          (aref (ant:ants-window a) 0) 90)
    (ant:stall-step! w)
    (is (zerop (aref (ant:ants-stalled a) 0)))
    (is (zerop (aref (ant:ants-walked a) 0)))
    (is (zerop (aref (ant:ants-window a) 0)))
    ;; and the fresh window is anchored on where it actually is
    (is (= (aref (ant:ants-h0x a) 0) (aref (ant:ants-hvx a) 0)))
    (is (= (aref (ant:ants-h0y a) 0) (aref (ant:ants-hvy a) 0)))))

(test the-pedometer-counts-walking-not-ground-made-good
  "ANTS-WALKED is the step the ant *attempted*, which is the whole of the
pinned signal: an ant shoving at a wall is walking, and the fact that
none of it becomes ground is exactly what it needs to find out.  Closed
over net displacement instead, L and |h-h0| would be the same quantity
and the first gap would be identically zero.

The arena boundary is the cheap way to hold an ant still while it walks
at full speed, the same trick PATH-INTEGRATION-TRACKS-ACTUAL-DISPLACEMENT
uses."
  (let* ((ant:*stall-window* 0)         ; isolate the pedometer itself
         (w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 8))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :stock 1.0f6))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:world-seed-population! w c 1)
    (let ((bi (aref (ant:ants-body a) 0)))
      (setf (aref (ant:bodies-x b) bi) 0.0f0
            (aref (ant:bodies-y b) bi) 0.5f0
            (aref (ant:ants-state a) 0) ant:+ant-outbound+
            (aref (ant:ants-walked a) 0) 0.0f0)
      (dotimes (k 200)
        (setf (aref (ant:ants-energy a) 0) 1.0f0
              (aref (ant:ants-heading a) 0) 3.1415927f0)  ; into the wall
        (ant:world-step! w))
      (is (< (aref (ant:bodies-x b) bi) 0.02f0)
          "the ant was supposed to stay pinned at the wall")
      ;; 200 ticks at ~2 cm/s is about 20 cm of walking, none of it ground
      (is (> (aref (ant:ants-walked a) 0) 0.15f0)
          "walked ~,4f m while stepping for 10 s"
          (aref (ant:ants-walked a) 0)))))

(test a-pinned-ant-notices-it-is-pinned
  "Both of the ant-oscillation bugs in this repository's history are the
first gap — 12 mm in 20 000 ticks (ANT-HANDEDNESS) and 8 mm in 20 000
(*homing-scan-steps*) — and neither ant had any way to notice.  This is
that way, end to end, on a live tick loop.

The off position is asserted too.  A sensor whose consequence also
appears without it is not being tested, and *stall-window* = 0 is the
exact off switch."
  (flet ((ever-cast (window)
           (let* ((ant:*stall-window* window)
                  (w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 8))
                  (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0
                                       :stock 1.0f6))
                  (a (ant:world-ants w))
                  (b (ant:world-bodies w)))
             (ant:world-seed-population! w c 1)
             (let ((bi (aref (ant:ants-body a) 0)))
               (setf (aref (ant:bodies-x b) bi) 0.0f0
                     (aref (ant:bodies-y b) bi) 0.5f0
                     (aref (ant:ants-state a) 0) ant:+ant-outbound+)
               (dotimes (k 300 nil)
                 (setf (aref (ant:ants-energy a) 0) 1.0f0
                       (aref (ant:ants-heading a) 0) 3.1415927f0)
                 (ant:world-step! w)
                 (when (plusp (aref (ant:ants-cast a) 0))
                   (return t)))))))
    (is-true (ever-cast 100)
             "walked into a wall for 15 s and never noticed")
    (is-false (ever-cast 0)
              "noticed with the window switched off, so this test does
not test the window")))

;;; ------------------------------------- Layer 3: the no-entry field
;;;
;;; The colony's only *fast* negative feedback.  Everything else it can do
;;; to stop recruiting runs at the speed of evaporation — tens of minutes —
;;; so a branch that has stopped paying keeps dispatching ants for another
;;; *trail-tau*, which is the loop behind the collapse traced in §3.4.
;;;
;;; The first test here is the one that matters most, and it is a
;;; prohibition rather than a behaviour.

(defun %repel-world ()
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 16))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :nest-r 0.02f0
                              :stock 1.0f6)))
    (values w c)))

(test the-nest-door-is-never-marked
  "The load-bearing prohibition, and the reason the two Layer 0 gaps are
kept apart at all.

The densest crowd in any run is the queue at the nest entrance.  It is
emergent, it is correct, and §3.11 and *nest-arrival-radius* both record
it as such — and every ant in it is stalled, jostled and getting nowhere
by any measure this model has.  If that could deposit, the colony would
chemically write off its own front door and starve in a ring around it,
which is precisely the failure widening the arrival radius had to fix.

Crowding is not an obstacle.  It clears."
  (multiple-value-bind (w c) (%repel-world)
    ;; every direction, at and just inside the arrival radius
    (dotimes (k 12)
      (let* ((ang (* 0.5236f0 k))
             (r (* 0.9f0 ant:*nest-arrival-radius*)))
        (ant:repel-deposit! w c (+ 0.5f0 (* r (cos ang)))
                            (+ 0.5f0 (* r (sin ang))) 5.0f0)))
    (ant:field-step! (ant:colony-repel c))
    (is (zerop (ant:field-total (ant:colony-repel c)))
        "the colony marked its own doorway: ~,4f units"
        (ant:field-total (ant:colony-repel c))))
  ;; and the exclusion is a radius, not a blanket ban — ground further out
  ;; is markable, or the rule would do nothing at all
  (multiple-value-bind (w c) (%repel-world)
    (ant:repel-deposit! w c 0.80f0 0.5f0 5.0f0)
    (ant:field-step! (ant:colony-repel c))
    (is (plusp (ant:field-total (ant:colony-repel c)))
        "nothing anywhere is markable, so the prohibition proves nothing")))

(test a-live-source-is-never-marked-but-a-dry-one-is
  "The same argument one step out: ants pile up at food and the pile is
the point.  The asymmetry is the interesting half — a source that has run
dry is exactly a dead end worth marking, and that falls out of the
emptiness test rather than needing a rule of its own."
  (multiple-value-bind (w c) (%repel-world)
    (ant:add-food w 0.8f0 0.5f0 0.02f0 100.0f0)
    (ant:repel-deposit! w c 0.8f0 0.5f0 5.0f0)
    (ant:field-step! (ant:colony-repel c))
    (is (zerop (ant:field-total (ant:colony-repel c)))
        "marked a source with 100 units still in it"))
  (multiple-value-bind (w c) (%repel-world)
    (let ((f (ant:add-food w 0.8f0 0.5f0 0.02f0 100.0f0)))
      (setf (ant:food-amount f) 0.0f0)
      (ant:repel-deposit! w c 0.8f0 0.5f0 5.0f0)
      (ant:field-step! (ant:colony-repel c))
      (is (plusp (ant:field-total (ant:colony-repel c)))
          "an exhausted source is a dead end and was not marked"))))

(test a-marked-direction-loses-the-choice
  "The field has to reach the choice function, and *repel-weight* = 0 has
to be an exact off position — a sensor whose consequence appears without
it is not being tested."
  (flet ((left-share (weight)
           (let ((ant:*repel-weight* weight)
                 ;; isolate the field's effect on the choice function: a
                 ;; lane offset slides the sample points sideways, which
                 ;; would move them off the single marked cell this test
                 ;; constructs
                 (ant:*trail-lane-offset* 0.0f0))
             (multiple-value-bind (w c) (%repel-world)
               ;; mark the left antenna's sample point only
               (let ((hl (- 0.0f0 ant:*sensor-spread*)))
                 (ant:field-deposit!
                  (ant:colony-repel c)
                  (+ 0.5f0 (* ant:*sensor-offset* (cos hl)))
                  (+ 0.5f0 (* ant:*sensor-offset* (sin hl)))
                  8.0f0))
               (ant:field-step! (ant:colony-repel c))
               (let ((left 0) (n 3000))
                 (dotimes (id n)
                   (when (< (ant:choose-turn w 0 id 7 0.5f0 0.5f0 0.0f0) 0.0f0)
                     (incf left)))
                 (/ (float left) n))))))
    (let ((marked (left-share 1.0f0))
          (off (left-share 0.0f0)))
      (is (< marked (* 0.6f0 off))
          "a marked direction was still chosen ~,3f of the time against ~,3f
unmarked, so the field is not reaching the choice function" marked off)
      (is (< (abs (- off 1/3)) 0.05f0)
          "with the field off the three directions must be equally likely,
and left came out ~,3f" off))))

(test a-homing-ant-routes-around-a-marked-pocket
  "Why the field has to reach CLEAR-BEARING as well, and not only the
choice function.

A laden ant's heading is set by the homing term *after* the choice
function has spoken, so whatever the antennae concluded is overwritten
before the ant moves — the same reason *homing-scan-steps* had to exist.
A returning ant is precisely the one that needs to route around a pocket,
so a mark that stops at the choice function does not reach the ants it is
for."
  (multiple-value-bind (w c) (%repel-world)
    (declare (ignore w))
    (let ((f (ant:colony-field c))
          (rf (ant:colony-repel c)))
      ;; heavily mark the ground due east of the ant
      (loop for dx from 0.0f0 to 0.03f0 by 0.004f0
            do (ant:field-deposit! rf (+ 0.5f0 dx) 0.5f0 40.0f0))
      (ant:field-step! rf)
      (let ((plain (ant:clear-bearing f 0.5f0 0.5f0 0.0f0 1.0f0
                                      ant:*sensor-offset*))
            (marked (ant:clear-bearing f 0.5f0 0.5f0 0.0f0 1.0f0
                                       ant:*sensor-offset* rf)))
        (is (< (abs plain) 1.0f-5)
            "open ground should return the bearing unchanged, got ~,4f" plain)
        (is (> (abs marked) 0.2f0)
            "the marked bearing was taken anyway: ~,4f" marked)))))

(test an-exhausted-source-marks-itself
  "End to end on a live tick loop: an ant that walks to a source and
finds nothing there says so.  This is the model's first fast brake — a
trail outliving its source can otherwise only be forgotten at the speed
of evaporation."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 16))
         (c (ant:add-colony w :nest-x 0.5f0 :nest-y 0.5f0 :stock 1.0f6))
         (f (ant:add-food w 0.8f0 0.5f0 0.02f0 100.0f0))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:world-seed-population! w c 1)
    (let ((bi (aref (ant:ants-body a) 0)))
      ;; standing on the source, which then runs out under it
      (setf (aref (ant:bodies-x b) bi) 0.8f0
            (aref (ant:bodies-y b) bi) 0.5f0
            (aref (ant:ants-state a) 0) ant:+ant-at-food+
            (ant:food-amount f) 0.0f0)
      (dotimes (k 40)
        (setf (aref (ant:ants-energy a) 0) 1.0f0)
        (ant:world-step! w))
      (is (plusp (ant:field-total (ant:colony-repel c)))
          "walked to an empty source and left no verdict"))))

;;; ------------------------------------------ when two ants meet (M3)
;;;
;;; The broad phase used to report only overlaps to be resolved.  These
;;; test it read as an *event* instead, and the three rules that ride on
;;; it: recognition, giving way, and the pairwise exchange §3.9 deferred.
;;;
;;; ANT-ENCOUNTER-STEP! is driven directly rather than through
;;; WORLD-STEP!, because a full tick also walks the ants, turns them by
;;; the choice function and adds heading noise — all of which would be
;;; measured here as if it were the encounter.  The hash is rebuilt by
;;; hand for the same reason: this is the pass under test and nothing else.

(defun %meet-world (&key (colonies 1) (n 4))
  "A world with N ants per colony, all placeable by hand."
  (let ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 64)))
    (dotimes (k colonies)
      (let ((c (ant:add-colony w :name (format nil "c~d" k)
                                 :nest-x (+ 0.2f0 (* 0.5f0 k)) :nest-y 0.9f0
                                 :stock 1.0f6)))
        (ant:world-seed-population! w c n)))
    w))

(defun %place! (w i x y heading state &key (crop 0.0f0) (energy 1.0f0))
  "Put ant I where the test wants it, body and all.

The body *kind* has to move with the state, because ANT-MOTION-STEP!
normally derives one from the other every tick and these tests do not run
it — an ant left as +BODY-RESTING+ is behind the nest door and takes no
part in ant-ant contact at all, so the whole fixture would silently
measure nothing.  That is exactly the drift the derivation exists to
prevent, met here from the other side."
  (let* ((a (ant:world-ants w))
         (b (ant:world-bodies w))
         (bi (aref (ant:ants-body a) i)))
    (setf (aref (ant:bodies-kind b) bi)
          (if (= state ant:+ant-in-nest+) ant:+body-resting+ ant:+body-ant+))
    (setf (aref (ant:bodies-x b) bi) (float x 1.0f0)
          (aref (ant:bodies-y b) bi) (float y 1.0f0)
          (aref (ant:ants-heading a) i) (float heading 1.0f0)
          (aref (ant:ants-state a) i) state
          (aref (ant:ants-crop a) i) (float crop 1.0f0)
          (aref (ant:ants-energy a) i) (float energy 1.0f0)
          (aref (ant:ants-confidence a) i) 0.0f0)))

(defun %encounter! (w)
  (ant:bodies-rebuild-hash! (ant:world-bodies w))
  (ant:ant-encounter-step! w))

(test a-laden-ant-has-the-right-of-way
  "Both ants give way; the question is how much.  A laden ant on its way
home yields least and an outbound ant most, which is the asymmetry the
traffic literature reports and the one the lane structure on a busy trail
is supposed to rest on.

Nothing in the model says 'walk on the left'.  If lanes appear on a
crowded trail they are a consequence of this ratio, which is why the
ratio is what gets asserted."
  (let ((w (%meet-world)))
    ;; head-on, slightly offset so the bearing is unambiguous
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
    (%place! w 1 0.507f0 0.502f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%encounter! w)
    (let* ((a (ant:world-ants w))
           (out (abs (aref (ant:ants-dturn a) 0)))
           (laden (abs (aref (ant:ants-dturn a) 1))))
      (is (plusp out) "the outbound ant did not give way at all")
      (is (plusp laden) "the laden ant did not give way at all")
      (is (> out (* 2.0f0 laden))
          "outbound yielded ~,4f against the laden ant's ~,4f, which is not
a right of way" out laden))))

(defun %pace-pair (w)
  "Two ant indices whose lifelong paces differ by at least 2%, faster
first, or NIL."
  (let* ((a (ant:world-ants w))
         (seed (ant:world-seed w)))
    (dotimes (i (ant:ants-n a))
      (dotimes (j (ant:ants-n a))
        (when (and (/= i j)
                   (> (ant:ant-pace (aref (ant:ants-id a) i) seed)
                      (* 1.02f0 (ant:ant-pace (aref (ant:ants-id a) j) seed))))
          (return-from %pace-pair (list i j)))))
    nil))

(test a-faster-ant-passes-a-slower-nestmate
  "Regression, and the hole this rule was originally written with.

*speed-spread* exists so that there is a fast ant behind a slow one — its
own docstring says so, and names overtaking as the thing that buys.  The
first version of the give-way rule fired only on *oncoming* ants, so a
nestmate going the same way produced no turn at all: the faster ant
walked into the back of the slower one and the collision solver held the
pair together at the slower pace.  Watched, that is a colony whose ants
visibly do not differ in speed, even though every one of them has a
different pace and the trait tests all pass.

So the trigger is *gaining*, not merely being near.  Both halves are
asserted, because a rule that made every following ant swerve would break
up the columns just as thoroughly from the other side."
  (let* ((w (%meet-world :n 8))
         (pair (%pace-pair w))
         (a (ant:world-ants w)))
    (is-true pair "no two ants in the fixture differ enough in pace")
    (when pair
      (destructuring-bind (fast slow) pair
        ;; the faster ant, behind, closing: it passes
        (%place! w fast 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
        (%place! w slow 0.506f0 0.500f0 0.0f0 ant:+ant-outbound+)
        (%encounter! w)
        (is (plusp (abs (aref (ant:ants-dturn a) fast)))
            "the faster ant queued behind the slower one instead of passing")
        ;; and the ant in front pays no attention to what is behind it
        (is (zerop (aref (ant:ants-dturn a) slow))
            "the leading ant swerved for something behind it: ~,4f"
            (aref (ant:ants-dturn a) slow))
        ;; And the follower pulls out whichever of the two it is, because
        ;; the trigger is *being obstructed* and not being nominally
        ;; quicker.
        ;;
        ;; That was the other way round at first, gated on comparing
        ;; free-walking speeds, and it fails in the one case that matters:
        ;; in a stalled column nobody is moving, so only the ants that
        ;; happen to be faster on paper ever try to pass and the rest
        ;; shove.  What that produces is a queue whose leader presses a
        ;; wall while everyone behind presses into the ant in front —
        ;; which is what the letter pockets fill up with.
        (%place! w slow 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
        (%place! w fast 0.506f0 0.500f0 0.0f0 ant:+ant-outbound+)
        (%encounter! w)
        (is (plusp (abs (aref (ant:ants-dturn a) slow)))
            "an ant with a nestmate right in front of it kept shoving")
        (is (zerop (aref (ant:ants-dturn a) fast))
            "the leading ant swerved for something behind it: ~,4f"
            (aref (ant:ants-dturn a) fast))))))

(test overtaking-has-an-exact-off-position
  "*yield-overtake* = 0 restores queueing, which is how the rule behaved
before — so the measurement of what passing is worth has a baseline."
  (let ((ant:*yield-overtake* 0.0f0))
    (let* ((w (%meet-world :n 8))
           (pair (%pace-pair w))
           (a (ant:world-ants w)))
      (when pair
        (destructuring-bind (fast slow) pair
          (%place! w fast 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
          (%place! w slow 0.506f0 0.500f0 0.0f0 ant:+ant-outbound+)
          (%encounter! w)
          (is (zerop (aref (ant:ants-dturn a) fast))
              "passed with the rule switched off"))))))

(test a-head-on-meeting-still-outranks-a-pass
  "The three cases must stay ordered.  An oncoming nestmate is given way
to by role, and adding overtaking must not have quietly turned every
head-on meeting into a pass at the overtake weight."
  (let* ((w (%meet-world :n 8))
         (a (ant:world-ants w)))
    ;; laden, returning, meeting an outbound ant head-on
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
    (%place! w 1 0.506f0 0.502f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%encounter! w)
    (let ((out (abs (aref (ant:ants-dturn a) 0)))
          (laden (abs (aref (ant:ants-dturn a) 1))))
      (is (> out (* 2.0f0 laden))
          "right of way was lost: outbound ~,4f, laden ~,4f" out laden))))

(test a-stranger-is-avoided-harder-and-never-fed
  "Recognition, and it is kept deliberately small: a non-nestmate is
turned away from and nothing else.  No fighting, no alarm — those want
two colonies with something to fight over (§3.12).  What matters now is
that nestmate and stranger already take different paths.

The half that is easy to forget is the one asserted second.  A stranger
is not fed, and would not be believed either."
  (let ((w (%meet-world :colonies 2 :n 4)))
    ;; ant 0 is colony 0; ant 4 is colony 1
    (let ((a (ant:world-ants w)))
      (is (/= (aref (ant:ants-colony a) 0) (aref (ant:ants-colony a) 4))
          "the fixture did not actually produce two colonies"))
    ;; a laden nestmate pair, and the same geometry across colonies
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+ :energy 0.2f0)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%place! w 4 0.300f0 0.300f0 0.0f0 ant:+ant-outbound+ :energy 0.2f0)
    (%place! w 5 0.306f0 0.300f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    ;; ant 5 is colony 1's; move colony 0's ant 2 next to it instead
    (%place! w 2 0.700f0 0.700f0 0.0f0 ant:+ant-outbound+ :energy 0.2f0)
    (%place! w 6 0.706f0 0.700f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%encounter! w)
    (let* ((a (ant:world-ants w))
           (nestmate (abs (aref (ant:ants-dturn a) 0)))
           (stranger (abs (aref (ant:ants-dturn a) 2))))
      (is (> stranger (* 1.5f0 nestmate))
          "turned away from a stranger by ~,4f and a nestmate by ~,4f"
          stranger nestmate)
      (is (> (aref (ant:ants-energy a) 0) 0.2f0)
          "a hungry nestmate was not fed")
      (is (= (aref (ant:ants-energy a) 2) 0.2f0)
          "a stranger was fed: energy ~,4f" (aref (ant:ants-energy a) 2))
      (is (zerop (aref (ant:ants-confidence a) 2))
          "a stranger's full crop was taken as evidence"))))

(test a-laden-ant-feeds-a-hungry-nestmate
  "Trophallaxis — §3.9's 'only mechanism in the model needing pairwise
coupling', and it is: everything else an ant does it does to itself or to
a field.

What it buys is range.  Until now a forager made the whole round trip on
the reserve it set out with, so a colony's reach was set by one ant's
tank; a trail with laden ants coming back along it is a supply line."
  (let ((w (%meet-world)))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+ :energy 0.20f0)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+
             :crop 1.0f0 :energy 1.0f0)
    (%encounter! w)
    (let* ((a (ant:world-ants w))
           (given (- 1.0f0 (aref (ant:ants-crop a) 1)))
           (got (- (aref (ant:ants-energy a) 0) 0.20f0)))
      (is (> given 0.0f0) "the donor gave nothing")
      (is (> got 0.0f0) "the hungry ant received nothing")
      ;; and the books balance: crop is social food, and the same fraction
      ;; of it becomes usable energy here as it does at the nest
      (is (< (abs (- got (* given ant:*crop-to-energy*))) 1.0f-6)
          "gave ~,6f of crop and delivered ~,6f of energy" given got))))

(test a-full-ant-is-not-fed
  "The recipient has to be hungry, or a busy trail would be nothing but
ants handing food back and forth instead of carrying it home."
  (let ((w (%meet-world)))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+ :energy 1.0f0)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%encounter! w)
    (is (= 1.0f0 (aref (ant:ants-crop (ant:world-ants w)) 1))
        "fed an ant with a full tank")))

(test a-donor-cannot-give-away-more-than-it-carries
  "One partner per donor, and this is why.  A laden ant pressed round by
a crowd of hungry nestmates must not hand each of them a meal out of the
same crop — the queue at a source is exactly that geometry, and a rule
that paid out per neighbour would create food."
  (let ((w (%meet-world :n 6)))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-returning+
             :crop 0.003f0 :energy 1.0f0)   ; less crop than one full gift
    (%place! w 1 0.505f0 0.500f0 3.1415927f0 ant:+ant-outbound+ :energy 0.1f0)
    (%place! w 2 0.504f0 0.503f0 3.1415927f0 ant:+ant-outbound+ :energy 0.1f0)
    (%place! w 3 0.504f0 0.497f0 3.1415927f0 ant:+ant-outbound+ :energy 0.1f0)
    (%encounter! w)
    (let* ((a (ant:world-ants w))
           (fed (+ (- (aref (ant:ants-energy a) 1) 0.1f0)
                   (- (aref (ant:ants-energy a) 2) 0.1f0)
                   (- (aref (ant:ants-energy a) 3) 0.1f0))))
      (is (>= (aref (ant:ants-crop a) 0) 0.0f0)
          "the donor's crop went negative: ~,6f" (aref (ant:ants-crop a) 0))
      (is (< (abs (- fed (* 0.003f0 ant:*crop-to-energy*))) 1.0f-6)
          "three mouths drew ~,6f of energy from a crop worth ~,6f"
          fed (* 0.003f0 ant:*crop-to-energy*)))))

(test every-donor-sees-the-tick-as-it-began
  "The determinism discipline, and a sharp test of it.

Two donors, one recipient sitting just below the threshold at which it
would stop accepting food.  Read from a buffer, both donors see the
hunger the tick began with and both give.  Written in place, the second
donor would see a recipient the first had already lifted over the line
and would walk past — so the outcome would depend on the order the ant
table happens to be in, which is the determinism bug that survives every
test until the day something is threaded."
  (let* ((w (%meet-world))
         (a (ant:world-ants w))
         ;; The bar is the colony's departure threshold, not a flat
         ;; fraction of a tank (see *trophallaxis-threshold*), so the
         ;; fixture has to ask the colony what it is.
         (bar (* ant:*trophallaxis-threshold*
                 (ant:colony-energy-threshold
                  (first (ant:world-colonies w)))))
         ;; one gift lands it just above that bar
         (start (- bar (* 0.4f0 ant:*trophallaxis-rate*
                          ant:*crop-to-energy*))))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+ :energy start)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%place! w 2 0.494f0 0.500f0 0.0f0 ant:+ant-returning+ :crop 1.0f0)
    (%encounter! w)
    (let ((got (- (aref (ant:ants-energy a) 0) start))
          (one (* ant:*trophallaxis-rate* ant:*crop-to-energy*)))
      (is (> got (* 1.9f0 one))
          "received ~,6f, which is ~,2f gifts and not two — one donor saw
the other's transfer" got (/ got one)))))

(test news-from-a-laden-nestmate-buys-persistence-and-nothing-else
  "The whole of the social-information design, in one test.

An outbound ant that passes a loaded nestmate coming the other way learns
that this ground has been paying *recently*, which pheromone — an average
over the last several minutes — cannot tell it.  What it does **not**
learn is a direction: that was tested in this genus and came out negative
(Grüter, Czaczkes et al. 2017), and a model that let a contact hand over
a bearing would be inventing a channel the animal does not have.

So the second assertion is the important one.  With giving way switched
off, an encounter must move confidence and leave the heading exactly
where it was."
  (let ((ant:*yield-rate* 0.0f0))
    (let* ((w (%meet-world))
           (a (ant:world-ants w)))
      (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
      (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
      (%encounter! w)
      (is (plusp (aref (ant:ants-confidence a) 0))
          "passed a loaded nestmate and learned nothing")
      (is (= 0.0f0 (aref (ant:ants-heading a) 0))
          "a contact steered the ant to ~,4f; encounters must not carry a
direction" (aref (ant:ants-heading a) 0))))
  ;; an empty nestmate is no evidence at all
  (let* ((w (%meet-world))
         (a (ant:world-ants w)))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 0.0f0)
    (%encounter! w)
    (is (zerop (aref (ant:ants-confidence a) 0))
        "an empty nestmate was taken as evidence of food")))

(test confidence-goes-stale
  "A colony whose evidence never expired would keep sending ants down a
route for as long as it once worked — which is the failure the no-entry
field exists to cure, and would be perverse to reintroduce here."
  (let* ((w (%meet-world))
         (a (ant:world-ants w)))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (%encounter! w)
    (let ((peak (aref (ant:ants-confidence a) 0)))
      (is (plusp peak))
      ;; walk the informant away and let the news age
      (%place! w 1 0.900f0 0.900f0 0.0f0 ant:+ant-returning+ :crop 1.0f0)
      (dotimes (k 400) (%encounter! w))
      (is (< (aref (ant:ants-confidence a) 0) (* 0.5f0 peak))
          "confidence held at ~,4f of its peak over 20 s"
          (/ (aref (ant:ants-confidence a) 0) peak)))))

(test encounters-have-an-exact-off-position
  "*antennal-range* = 0 has to restore the model that had no encounters
at all, or none of the measurements above mean anything."
  (let ((ant:*antennal-range* 0.0f0))
    (let* ((w (%meet-world))
           (a (ant:world-ants w)))
      (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+ :energy 0.2f0)
      (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
      (%encounter! w)
      (is (zerop (aref (ant:ants-dturn a) 0)))
      (is (zerop (aref (ant:ants-confidence a) 0)))
      (is (= 1.0f0 (aref (ant:ants-crop a) 1)))
      (is (= 0.2f0 (aref (ant:ants-energy a) 0))))))

(test a-corpse-is-not-an-ant
  "The reverse map from body to ant has to survive a death.  A body
outlives the ant that had it — nothing removes a corpse (§3.11) — so a
stale entry would hand the encounter pass a dead ant's index, and every
rule here would then read the state of whatever ant next took that slot."
  (let* ((w (%meet-world))
         (a (ant:world-ants w))
         (colony (first (ant:world-colonies w))))
    (%place! w 0 0.500f0 0.500f0 0.0f0 ant:+ant-outbound+ :energy 0.2f0)
    (%place! w 1 0.506f0 0.500f0 3.1415927f0 ant:+ant-returning+ :crop 1.0f0)
    (let ((bi (aref (ant:ants-body a) 1)))
      (ant:kill-ant w colony 1)
      (is (= ant:+no-ant+ (aref (ant:ants-of-body a) bi))
          "the dead ant's body still points at an ant"))
    (%encounter! w)
    (is (zerop (aref (ant:ants-dturn a) 0))
        "gave way to a corpse")
    (is (= 0.2f0 (aref (ant:ants-energy a) 0))
        "a corpse handed over a meal")))
