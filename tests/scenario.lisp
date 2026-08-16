;;;; tests/scenario.lisp — the JSON scenario format (§6).

(in-package #:antsim/test)

(in-suite antsim)

(defun %scenario-path (name)
  (merge-pathnames (format nil "scenarios/~a" name)
                   (asdf:system-source-directory "antsim")))

(defun %polys (w)
  (mapcar (lambda (p) (coerce (ant:polygon-verts p) 'list))
          (ant:world-obstacles w)))

(test shipped-bridges-match-their-lisp-constructors
  "The scenario files and the Lisp constructors must build the *same*
apparatus, vertex for vertex.

This is the test that lets the JSON files be trusted.  The acceptance
rows run the Lisp constructors; the playground and the pictures use the
files.  If those drifted apart, the published result and the thing anyone
can actually look at would be different experiments with the same name —
and nothing else in the project would notice."
  (dolist (spec (list (cons "deneubourg-binary-bridge.json"
                            (ant:binary-bridge :seed 1))
                      (cons "goss-double-bridge.json"
                            (ant:double-bridge :seed 1))))
    (destructuring-bind (file . lisp-bridge) spec
      (let* ((s (ant:load-scenario (%scenario-path file)))
             (jw (ant:scenario-world s))
             (lw (ant:bridge-world lisp-bridge)))
        (is (= (ant:world-width jw) (ant:world-width lw))
            "~a: arena width differs" file)
        (is (= (ant:world-height jw) (ant:world-height lw))
            "~a: arena height differs" file)
        (is (equalp (%polys jw) (%polys lw))
            "~a: the obstacle geometry differs from the Lisp constructor"
            file)))))

(test a-scenario-cannot-author-ants-or-pheromone
  "§6's hard rule, as a test.

`start` seeds a count at the nest, never a layout, and there is no key
anywhere that puts pheromone on the grid.  Both of those are what make a
run a claim rather than a picture, so the format has to be unable to
express them — not merely discouraged from it."
  (flet ((try (json)
           (handler-case (progn (ant:load-scenario-string json) nil)
             (ant:scenario-error () t))))
    (is-true (try "{\"world\":{\"width\":0.4,\"height\":0.4},
                    \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.2}}],
                    \"ants\":[{\"x\":0.1,\"y\":0.1}]}")
             "a scenario was allowed to place an ant")
    (is-true (try "{\"world\":{\"width\":0.4,\"height\":0.4},
                    \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.2}}],
                    \"trail\":[[0.1,0.1,5.0]]}")
             "a scenario was allowed to paint pheromone")))

(test scenario-errors-name-the-offending-key
  "A silently-defaulted typo is a bug that costs an afternoon (§6), so
validation is strict and the message says where."
  (flet ((msg (json)
           (handler-case (progn (ant:load-scenario-string json) nil)
             (ant:scenario-error (e) (format nil "~a" e)))))
    ;; a misspelling inside a nested object names the full path
    (let ((m (msg "{\"world\":{\"width\":1,\"heigth\":1},
                    \"colonies\":[{\"nest\":{\"x\":0.5,\"y\":0.5}}]}")))
      (is-true (and m (search "world.heigth" m))
               "expected the path in the message, got: ~a" m))
    ;; a required key that is absent says so, and where
    (let ((m (msg "{\"world\":{\"height\":1},
                    \"colonies\":[{\"nest\":{\"x\":0.5,\"y\":0.5}}]}")))
      (is-true (and m (search "world.width" m))
               "expected the missing key named, got: ~a" m))
    ;; and a key §6 documents but this loader does not implement is told
    ;; apart from a typo, because the two need different answers
    (let ((m (msg "{\"world\":{\"width\":1,\"height\":1},\"clock\":{},
                    \"colonies\":[{\"nest\":{\"x\":0.5,\"y\":0.5}}]}")))
      (is-true (and m (search "not implemented" m))
               "a deferred key should not read as a typo, got: ~a" m))))

(test the-bridge-primitive-refuses-a-malformed-bridge
  "The primitive exists because a bridge written out as raw polygons is
unreadable and, worse, easy to get wrong in the one way that matters: an
extra way through the band.  So it checks its own preconditions."
  (flet ((try (arms)
           (handler-case
               (progn (ant:load-scenario-string
                       (format nil "{\"world\":{\"width\":1,\"height\":1},
                          \"colonies\":[{\"nest\":{\"x\":0.5,\"y\":0.1}}],
                          \"obstacles\":[{\"bridge\":{\"y_lo\":0.3,
                            \"y_hi\":0.6,\"arms\":~a}}]}" arms))
                      nil)
             (ant:scenario-error (e) (format nil "~a" e)))))
    (is-true (try "[{\"bottom\":0.4}]")
             "a one-armed bridge was accepted")
    (is-true (try "[{\"bottom\":0.6},{\"bottom\":0.4}]")
             "arms out of left-to-right order were accepted")
    (is-false (try "[{\"bottom\":0.4},{\"bottom\":0.6}]")
              "a well-formed two-arm bridge was rejected")))

(test a-scenario-seed-can-be-overridden-without-editing-the-file
  "The window draws a fresh seed for each session, so one scenario file
has to be runnable as many different replicates.

The override has to reach MAKE-WORLD rather than being assigned
afterwards: the seed is fixed when the world is built, and the starting
population is placed with it, so a seed set after loading would change
the ants' *decisions* while leaving their starting positions from the
file's seed — two runs spliced together, and reproducible as neither.

Determinism is untouched by any of this. It is a property of the model
given a seed, and this only changes which seed is given."
  (flet ((fingerprint (s ticks)
           (let ((w (ant:scenario-world s)))
             (ant:world-run! w ticks)
             (let ((b (ant:world-bodies w)) (acc 0.0d0))
               (dotimes (i (min 300 (ant:bodies-n b)))
                 (incf acc (+ (aref (ant:bodies-x b) i)
                              (* 3 (aref (ant:bodies-y b) i)))))
               acc)))
         (scn (&rest args)
           (apply #'ant:load-scenario-string
                  "{\"world\":{\"width\":0.4,\"height\":0.4},
                    \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.1},
                                   \"start\":60,\"stock\":200.0}],
                    \"food\":[{\"x\":0.2,\"y\":0.3,\"amount\":9000.0}],
                    \"seed\":1}"
                  args)))
    (let ((a (fingerprint (scn) 400))
          (b (fingerprint (scn) 400))
          (c (fingerprint (scn :seed 7) 400))
          (d (fingerprint (scn :seed 7) 400))
          (e (fingerprint (scn :seed 8) 400)))
      (is (= a b) "the file's own seed did not reproduce: ~,4f vs ~,4f" a b)
      (is (= c d) "seed 7 did not reproduce: ~,4f vs ~,4f" c d)
      (is (/= a c) "overriding the seed changed nothing")
      (is (/= c e) "two different seeds gave the same run")
      (is (= 7 (ant:world-seed (ant:scenario-world (scn :seed 7))))
          "the override did not reach the world"))))

(test food-radius-tracks-how-much-food-there-is
  "The drawn disc has to answer 'how much is there', not 'how much of it
is left'.

Before density existed the radius was a fraction of whatever the source
happened to start with, so a pile of 500 000 units and one of 2 500
looked exactly alike at full — which is the one thing a picture of a food
source should never do. With a density, area is amount/density and the
radius is absolute: two sources side by side can be compared by eye."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 100))
         (big (ant:add-food w 0.2f0 0.5f0 0.03f0 4000.0f0 :density 1.0f6))
         (small (ant:add-food w 0.8f0 0.5f0 0.03f0 1000.0f0 :density 1.0f6)))
    (is (> (ant:food-current-radius big) (ant:food-current-radius small))
        "four times the food did not draw larger at the same density")
    ;; four times the amount is twice the radius, because area is the
    ;; quantity
    (is (< (abs (- (ant:food-current-radius big)
                   (* 2.0f0 (ant:food-current-radius small))))
           1.0f-4)
        "~,4f vs ~,4f — area is not tracking amount"
        (ant:food-current-radius big) (ant:food-current-radius small))
    ;; and eating half of it takes the radius to 1/sqrt(2)
    (let ((r0 (ant:food-current-radius big)))
      (setf (ant:food-amount big) 2000.0f0)
      (is (< (abs (- (ant:food-current-radius big) (/ r0 (sqrt 2.0f0))))
             1.0f-4)
          "half eaten should be 1/sqrt(2) of the radius"))))

(test a-source-without-a-density-behaves-exactly-as-before
  "Density is an addition, not a change: a scenario that gives only a
radius must produce the run it always did."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 100))
         (f (ant:add-food w 0.5f0 0.5f0 0.03f0 2500.0f0)))
    (is (< (abs (- (ant:food-current-radius f) 0.03f0)) 1.0f-5)
        "a full source should be drawn at its authored radius, got ~,5f"
        (ant:food-current-radius f))
    (setf (ant:food-amount f) 625.0f0)     ; a quarter left
    (is (< (abs (- (ant:food-current-radius f) 0.015f0)) 1.0f-5)
        "a quarter left should be half the radius, got ~,5f"
        (ant:food-current-radius f))))

(test a-scenario-may-carry-comments
  "JSON has no comment syntax, and a scenario that cannot say why it uses
a number is one whose numbers get changed by someone who does not know.
Underscore keys are ignored; strictness is for typos, and a typo does not
begin with an underscore."
  (let ((s (ant:load-scenario-string
            "{\"_why\":\"because\",
              \"world\":{\"width\":0.4,\"height\":0.4,\"_note\":\"small\"},
              \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.2}}]}")))
    (is-true (ant:scenario-world s) "a commented scenario failed to load")))

(test scenario-parameters-are-carried-not-applied
  "A scenario that sets tau and then runs under the default tau would be
a particularly cruel bug, so the overrides are kept on the scenario and
bound around the run."
  (let ((s (ant:load-scenario-string
            "{\"world\":{\"width\":0.4,\"height\":0.4},
              \"choice\":{\"n\":1.0,\"k\":5.0},
              \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.2}}]}")))
    (is (= 2.0f0 ant:*choice-n*)
        "loading a scenario changed the global parameter set")
    (ant:with-scenario-params (s)
      (is (= 1.0f0 ant:*choice-n*) "the override was not in force")
      (is (= 5.0f0 ant:*choice-k*)))
    (is (= 2.0f0 ant:*choice-n*) "the override outlived its dynamic extent")))

(test a-scenario-can-set-the-ant-itself
  "§6: the `ant` block, which exists because arena size is the one thing
a scene can change that the ant's own calibration cannot absorb.

A forager's tank is fixed and was set against a 1 m arena; a scenario
that spans metres has to be able to say so, or nothing ever reaches the
food.  Carried like every other override rather than applied at load, for
the same reason: a scenario that sets a range and then runs at the
default range is the bug this whole mechanism exists to prevent."
  (let ((s (ant:load-scenario-string
            "{\"world\":{\"width\":0.4,\"height\":0.4},
              \"ant\":{\"_why\":\"a comment\",
                       \"energy_drain_walking\":0.000024,
                       \"energy_drain_resting\":0.000004,
                       \"speed_spread\":0.2},
              \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.2}}]}"))
        (drain ant:*energy-drain-walking*)
        (spread ant:*speed-spread*))
    (is (= drain ant:*energy-drain-walking*)
        "loading a scenario changed the global parameter set")
    (ant:with-scenario-params (s)
      (is (= 2.4f-5 ant:*energy-drain-walking*) "the range override was not in force")
      (is (= 4.0f-6 ant:*energy-drain-resting*))
      (is (= 0.2f0 ant:*speed-spread*)))
    (is (= drain ant:*energy-drain-walking*)
        "the override outlived its dynamic extent")
    (is (= spread ant:*speed-spread*)))
  ;; and a typo in the block is an error naming the path, not a default
  (signals ant:scenario-error
    (ant:load-scenario-string
     "{\"world\":{\"width\":0.4,\"height\":0.4},
       \"ant\":{\"enrgy_drain_walking\":0.00001},
       \"colonies\":[{\"nest\":{\"x\":0.2,\"y\":0.2}}]}")))

(test the-large-word-scenario-scales-only-the-geometry
  "`scenarios/antsim-large.json` is `antsim.json` five times over in every
length — and *only* in length.  The ant is the same animal in both, which
is the whole reason the large one is a different experiment rather than
the same picture printed bigger.

What it does have to restate is range: the forager's tank was calibrated
against a 1 m arena, and at the default a colony in the large one ate 8
units in thirty minutes and fell from 2000 workers to 26.  So the range
scales with the arena, and this checks it scales by exactly the same
factor the geometry does — otherwise a journey is a different fraction of
a tank in the two files and they stop being comparable."
  (let ((small (ant:load-scenario #p"scenarios/antsim.json"))
        (large (ant:load-scenario #p"scenarios/antsim-large.json")))
    (let ((ws (ant:world-width (ant:scenario-world small)))
          (wl (ant:world-width (ant:scenario-world large)))
          (hs (ant:world-height (ant:scenario-world small)))
          (hl (ant:world-height (ant:scenario-world large))))
      (is (< (abs (- (/ wl ws) 5.0f0)) 1.0f-4) "width ratio ~,4f" (/ wl ws))
      (is (< (abs (- (/ hl hs) 5.0f0)) 1.0f-4) "height ratio ~,4f" (/ hl hs)))
    ;; the same letters, so the same number of rects
    (is (= (length (ant:world-obstacles (ant:scenario-world small)))
           (length (ant:world-obstacles (ant:scenario-world large))))
        "the two files do not spell the same word")
    ;; the small one states nothing about the ant; the large one must
    (is (null (ant:scenario-params small))
        "the small scenario has acquired parameter overrides")
    (let ((drain (cdr (assoc 'ant:*energy-drain-walking*
                             (ant:scenario-params large)))))
      (is (not (null drain))
          "the large scenario does not set the forager's range")
      (is (< (abs (- (/ ant:*energy-drain-walking* drain) 5.0f0)) 1.0f-3)
          "range scaled by ~,3f but the arena by 5"
          (/ ant:*energy-drain-walking* drain)))))
