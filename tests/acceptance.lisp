;;;; tests/acceptance.lisp — §3.8 rows that are experiments, not properties.
;;;;
;;;; Most of the suite tests a function.  These two test a *result*, and
;;;; they only mean anything run as the published experiment — which is
;;;; why the apparatus lives in src/world/bridge.lisp and why these are
;;;; stated in the papers' own terms.
;;;;
;;;; Their own suite, and their own make target, because they are slow:
;;;; each row is several simulated colony-minutes per replicate and the
;;;; claims are about a distribution over seeds, so a single fast run
;;;; cannot stand in for them.  `make test` stays quick; `make acceptance`
;;;; is what says the science works.
;;;;
;;;; Sources for both rows, and for the numbers they assert:
;;;;
;;;;   Deneubourg, Aron, Goss & Pasteels (1990), "The self-organizing
;;;;   exploratory pattern of the Argentine ant", J. Insect Behavior 3:159.
;;;;   Two arms of equal length; the colony commits to one, and which one
;;;;   is not a property of the colony.
;;;;
;;;;   Goss, Aron, Deneubourg & Pasteels (1989), "Self-organized shortcuts
;;;;   in the Argentine ant", Naturwissenschaften 76:579.  Unequal arms;
;;;;   the short one wins, and nothing measures a length.
;;;;
;;;; Both were done with the Argentine ant; this model is parameterised
;;;; for Lasius niger.  The mechanism is the same and the result should
;;;; be, which is itself a claim worth having a test for.

(in-package #:antsim/test)

(def-suite acceptance)
(in-suite acceptance)

(defparameter *bridge-seeds* '(1 2 3)
  "Replicates per row.  Small, because each is a several-minute colony
run; large enough that 'varies with seed' has something to vary over.")

(defun %run-bridge (b)
  "Let the colony commit, then measure a clean window.

Two phases because the interesting quantity is the *committed* traffic
split.  Counting from tick zero would fold in the exploratory phase,
where the split genuinely is near even, and would understate a real
commitment rather than overstate it."
  (ant:bridge-run! b (* 1200 6))
  (ant:bridge-reset-counts! b)
  (ant:bridge-run! b (* 1200 6))
  b)

(test symmetry-breaking-on-a-binary-bridge
  "§3.8: two arms of *equal* length; ≥80% of traffic ends on one of them,
and which one varies with the seed.

Both halves are the claim, and the second is the harder one. A model that
always picked the left arm would pass the first half and be broken — the
result is that the colony *makes a choice*, not that it has a preference.
This is Deneubourg's binary bridge (1990).

The arms are the same length to the last float, which the test asserts
rather than assumes: if the apparatus is asymmetric then a lopsided split
proves nothing at all, and that is a failure mode that looks exactly like
success."
  (let ((winners '()) (shares '()) (lengths nil))
    (dolist (seed *bridge-seeds*)
      (let ((b (%run-bridge (ant:binary-bridge :seed seed))))
        (unless lengths (setf lengths (ant:bridge-lengths b)))
        (push (ant:bridge-winner b) winners)
        (push (reduce #'max (ant:bridge-share b)) shares)))
    ;; the apparatus itself
    (is (< (abs (- (first lengths) (second lengths))) 1.0f-6)
        "the arms are ~,4f and ~,4f — an asymmetric bridge cannot test ~
         symmetry breaking" (first lengths) (second lengths))
    ;; ... it commits ...
    (dolist (s shares)
      (is (>= s 0.80f0)
          "a replicate finished at ~,3f on its busiest arm; the colony ~
           did not commit" s))
    ;; ... and the choice is not the model's
    (is (> (length (remove-duplicates winners)) 1)
        "all ~d replicates chose the same arm (~a) — that is a preference, ~
         not symmetry breaking" (length winners) winners)))

(test the-short-arm-wins-on-a-double-bridge
  "§3.8: arms of *unequal* length; the short one wins, reliably, across
seeds.

Goss's double bridge (1989).  The mechanism is worth stating because it
is the whole reason this is interesting: nothing in the model measures a
distance, compares two routes, or knows an arm exists.  Ants on the short
arm simply complete the round trip sooner, so they lay on it sooner and
more often per unit time, and the nonlinearity does the rest.

Contrast with the binary bridge deliberately: there, *which* arm wins
must vary between seeds. Here it must not."
  (let ((winners '()) (shares '()) (ratio nil))
    (dolist (seed *bridge-seeds*)
      (let ((b (%run-bridge (ant:double-bridge :seed seed))))
        (unless ratio
          (setf ratio (/ (second (ant:bridge-lengths b))
                         (first (ant:bridge-lengths b)))))
        (push (ant:bridge-winner b) winners)
        (push (first (ant:bridge-share b)) shares)))
    (is (> ratio 1.5f0)
        "arm 1 is only ~,2fx arm 0; too close to call this a shortest-path ~
         result" ratio)
    (is (every (lambda (win) (eql win 0)) winners)
        "the short arm did not win every replicate: winners ~a" winners)
    (dolist (s shares)
      (is (>= s 0.60f0)
          "the short arm took only ~,3f of traffic in one replicate" s))))
