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
