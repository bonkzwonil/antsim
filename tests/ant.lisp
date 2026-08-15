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

(test hunger-lowers-both-energy-thresholds-together
  "The bar for setting out and the bar for giving up are one number.

They have to move together.  Lowering only the first would push a
starving ant out of the nest and turn it round on the very next tick,
which is the same deadlock standing in a different place."
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
