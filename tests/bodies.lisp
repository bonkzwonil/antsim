;;;; tests/bodies.lisp — the non-overlap rule (§3.11).
;;;;
;;;; One of these is an acceptance row rather than a unit test: "bodies
;;;; never interpenetrate — dense crowd at one small source" is in §3.8's
;;;; table, and BODIES-CROWD-RESOLVES is it.

(in-package #:antsim/test)

(in-suite antsim)

(defun make-test-bodies (&key (capacity 400) (width 1.0f0) (height 1.0f0))
  (ant:make-bodies capacity :cell 0.05f0 :width width :height height))

(defun overlapping-pairs (b &optional (slop 1e-5))
  "Brute-force count of blocking pairs that overlap by more than SLOP.
Deliberately quadratic and independent of the spatial hash: if the hash
were dropping pairs, a test that used it would agree with the bug."
  (let ((n (ant:bodies-n b))
        (xs (ant:bodies-x b)) (ys (ant:bodies-y b))
        (rs (ant:bodies-r b)) (ks (ant:bodies-kind b))
        (count 0))
    (dotimes (i n count)
      (loop for j from (1+ i) below n
            do (when (and (ant:body-kind-blocking-p (aref ks i))
                          (ant:body-kind-blocking-p (aref ks j)))
                 (let* ((dx (- (aref xs i) (aref xs j)))
                        (dy (- (aref ys i) (aref ys j)))
                        (sum (+ (aref rs i) (aref rs j)))
                        (d (sqrt (+ (* dx dx) (* dy dy)))))
                   (when (< d (- sum slop)) (incf count))))))))

(test bodies-alloc-and-free-reuse-slots
  (let ((b (make-test-bodies :capacity 4)))
    (let ((i0 (ant:bodies-alloc b 0.1f0 0.1f0 0.01f0 ant:+body-ant+))
          (i1 (ant:bodies-alloc b 0.2f0 0.2f0 0.01f0 ant:+body-ant+)))
      (is (= 0 i0))
      (is (= 1 i1))
      (ant:bodies-free! b i0)
      ;; the freed slot comes back before the table grows
      (is (= 0 (ant:bodies-alloc b 0.3f0 0.3f0 0.01f0 ant:+body-ant+)))
      (is (= 2 (ant:bodies-alloc b 0.4f0 0.4f0 0.01f0 ant:+body-ant+))))))

(test bodies-full-table-is-a-state-not-an-error
  "§3.10 caps the population, so a full table is a legitimate outcome of
a colony that is thriving — not a condition to signal on."
  (let ((b (make-test-bodies :capacity 2)))
    (is (= 0 (ant:bodies-alloc b 0.1f0 0.1f0 0.01f0 ant:+body-ant+)))
    (is (= 1 (ant:bodies-alloc b 0.2f0 0.2f0 0.01f0 ant:+body-ant+)))
    (is (null (ant:bodies-alloc b 0.3f0 0.3f0 0.01f0 ant:+body-ant+)))))

(test bodies-separate-a-simple-overlap
  (let ((b (make-test-bodies)))
    (ant:bodies-alloc b 0.500f0 0.5f0 0.01f0 ant:+body-ant+)
    (ant:bodies-alloc b 0.505f0 0.5f0 0.01f0 ant:+body-ant+)
    (is (= 1 (overlapping-pairs b)))
    (ant:bodies-resolve! b '() :iterations 6)
    (is (= 0 (overlapping-pairs b)))))

(test bodies-crowd-resolves
  "§3.8 acceptance row: *bodies never interpenetrate*, at any density.
120 ants dropped *inside* a 3 cm food source is far worse than anything
the sim produces — a rich source with a queue is the real case — and the
constraint is soft, so the claim is that the residual reaches zero given
enough iterations, not that one tick's worth is enough.

This is the test that caught the broad-phase query radius being too
small to see ant-versus-food contacts at all.  It stalled at a
non-zero residual no matter how long it ran, which is the signature of
missing constraints rather than unsatisfied ones."
  (let ((b (make-test-bodies :capacity 200)))
    ;; the source: immovable, and much larger than an ant
    (ant:bodies-alloc b 0.5f0 0.5f0 0.03f0 ant:+body-food+)
    ;; the crowd: piled into a 4 cm box on top of it
    (dotimes (i 120)
      (ant:bodies-alloc b
                        (+ 0.48f0 (* 0.04f0 (ant:rnd01 i 0 0)))
                        (+ 0.48f0 (* 0.04f0 (ant:rnd01 i 0 1)))
                        ant:*ant-radius* ant:+body-ant+))
    (is (> (overlapping-pairs b) 100) "the fixture should start badly overlapped")
    (ant:bodies-resolve! b '() :iterations 150)
    (is (= 0 (overlapping-pairs b))
        "~d pairs still overlap after relaxation" (overlapping-pairs b))))

(test bodies-immovable-kinds-do-not-move
  "A food source is a fixed point in the scenario; ants queue around it
rather than shoving it across the arena."
  (let ((b (make-test-bodies)))
    (let ((food (ant:bodies-alloc b 0.5f0 0.5f0 0.03f0 ant:+body-food+)))
      (dotimes (i 20)
        (ant:bodies-alloc b
                          (+ 0.49f0 (* 0.02f0 (ant:rnd01 i 5 0)))
                          (+ 0.49f0 (* 0.02f0 (ant:rnd01 i 5 1)))
                          ant:*ant-radius* ant:+body-ant+))
      (ant:bodies-resolve! b '() :iterations 20)
      (is (= 0.5f0 (aref (ant:bodies-x b) food)))
      (is (= 0.5f0 (aref (ant:bodies-y b) food))))))

(test nest-entrance-does-not-block
  "The deliberate exception (§3.11): making the entrance blocking would
seal the colony in.  It is a trigger, not a wall."
  (let ((b (make-test-bodies)))
    (let ((nest (ant:bodies-alloc b 0.5f0 0.5f0 0.03f0 ant:+body-nest+))
          (a (ant:bodies-alloc b 0.5f0 0.5f0 ant:*ant-radius* ant:+body-ant+)))
      (declare (ignore nest))
      (ant:bodies-resolve! b '() :iterations 5)
      ;; the ant sits at the nest centre, undisturbed
      (is (< (abs (- (aref (ant:bodies-x b) a) 0.5f0)) 1e-5))
      (is (< (abs (- (aref (ant:bodies-y b) a) 0.5f0)) 1e-5)))))

(test corpses-block-and-are-pushable
  "Corpses clutter (§3.11) — they get in the way, but they are inert
rather than anchored, so a crowd can shove one aside."
  (let ((b (make-test-bodies)))
    (let ((corpse (ant:bodies-alloc b 0.5f0 0.5f0 ant:*ant-radius*
                                    ant:+body-corpse+)))
      (ant:bodies-alloc b 0.5f0 0.5f0 ant:*ant-radius* ant:+body-ant+)
      (ant:bodies-resolve! b '() :iterations 10)
      (is (= 0 (overlapping-pairs b)))
      ;; it blocked (something had to move) and it moved (it is pushable)
      (is (or (/= 0.5f0 (aref (ant:bodies-x b) corpse))
              (/= 0.5f0 (aref (ant:bodies-y b) corpse)))))))

(test bodies-pushed-out-of-obstacles
  (let ((b (make-test-bodies))
        (wall (list (square 0.4 0.4 0.6 0.6))))
    (let ((inside (ant:bodies-alloc b 0.5f0 0.5f0 ant:*ant-radius*
                                    ant:+body-ant+))
          (edge (ant:bodies-alloc b 0.399f0 0.5f0 ant:*ant-radius*
                                  ant:+body-ant+)))
      (ant:bodies-resolve! b wall :iterations 20)
      (dolist (i (list inside edge))
        (let ((x (aref (ant:bodies-x b) i)) (y (aref (ant:bodies-y b) i)))
          (is-false (ant:point-in-polygon-p (first wall) x y)
                    "body ~d is inside the obstacle at ~a ~a" i x y))))))

(test bodies-resolution-is-deterministic
  "Jacobi rather than Gauss-Seidel exists for exactly this (§3.11): the
result must not depend on the order pairs happen to be visited."
  (flet ((settle ()
           (let ((b (make-test-bodies :capacity 100)))
             (dotimes (i 60)
               (ant:bodies-alloc b
                                 (+ 0.45f0 (* 0.1f0 (ant:rnd01 i 11 0)))
                                 (+ 0.45f0 (* 0.1f0 (ant:rnd01 i 11 1)))
                                 ant:*ant-radius* ant:+body-ant+))
             (ant:bodies-resolve! b (list (square 0.30 0.30 0.38 0.60))
                                  :iterations 8)
             (list (copy-seq (ant:bodies-x b)) (copy-seq (ant:bodies-y b))))))
    (let ((a (settle)) (b (settle)))
      (is (equalp (first a) (first b)))
      (is (equalp (second a) (second b))))))
