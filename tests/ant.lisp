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
  (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 32))
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
  "Regression.  A resting ant is a blocking body, so the crowd at a busy
nest shoves it, and path integration records the drift.  Departure used
to zero the home vector — which told the ant that wherever it had been
pushed to *was* home.  It would forage, return to that false origin, read
a home vector of zero and sit there with a full crop it could not unload.

Reported from the live window, where a stuck ant is obvious.  No
aggregate — population, stock, trail total — showed anything wrong."
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
