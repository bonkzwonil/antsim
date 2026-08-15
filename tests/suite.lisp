;;;; tests/suite.lisp — FiveAM suite for the antsim core.
;;;;
;;;; No GPU, no graphics stack, no dependencies beyond FiveAM: this suite
;;;; must run anywhere, because it is what guards the two properties the
;;;; whole simulation rests on — a random stream that is a pure function of
;;;; its coordinates, and a work split that does not depend on thread
;;;; timing (README §4.4, §4.5).

;;; `ant:` below is antsim's own global nickname, so no local nickname is
;;; declared — declaring one that shadows an existing global nickname is
;;; asking an implementation-defined question for no benefit.
(defpackage #:antsim/test
  (:use #:cl #:fiveam)
  (:export #:antsim))

(in-package #:antsim/test)

(def-suite antsim)
(in-suite antsim)

;;; ------------------------------------------------------------- util

(test array-constructors-are-specialized
  "Unspecialized arrays box every float, which is both slower and a
garbage source in the one loop that must not allocate."
  (is (typep (ant:mkf32 4) 'ant:f32v))
  (is (typep (ant:mku32 4) 'ant:u32v))
  (is (typep (ant:mku16 4) 'ant:u16v))
  (is (typep (ant:mku8 4) 'ant:u8v))
  (is (typep (ant:mkfix 4) 'ant:fixv))
  (is (= 4 (length (ant:mkf32 4))))
  (is (every (lambda (x) (= x 2.5)) (ant:mkf32 3 2.5f0))))

(test scalar-helpers
  (is (= 1.0f0 (ant:clampf 5.0f0 0.0f0 1.0f0)))
  (is (= 0.0f0 (ant:clampf -5.0f0 0.0f0 1.0f0)))
  (is (= 0.5f0 (ant:clampf 0.5f0 0.0f0 1.0f0)))
  (is (= 2.0f0 (ant:lerpf 0.0f0 4.0f0 0.5f0)))
  (is (= 0.0f0 (ant:lerpf 0.0f0 4.0f0 0.0f0)))
  (is (= 4.0f0 (ant:lerpf 0.0f0 4.0f0 1.0f0)))
  (is (= 9.0f0 (ant:sqf 3.0f0)))
  (is (= 9.0f0 (ant:sqf -3.0f0))))

;;; -------------------------------------------------------------- rng
;;;
;;; The RNG is not a convenience here.  Every acceptance run in §3.8 is
;;; reproducible only because rnd01 is a pure function of (id, tick,
;;; stream), so these tests are guarding a design decision, not a utility.

(test rnd01-stays-in-range
  (let ((lo 1.0f0) (hi 0.0f0))
    (dotimes (tick 200)
      (dotimes (id 200)
        (let ((r (ant:rnd01 id tick)))
          (is-true (and (<= 0.0f0 r) (< r 1.0f0))
                   "rnd01(~d,~d) = ~a is outside [0,1)" id tick r)
          (setf lo (min lo r) hi (max hi r)))))
    ;; and it must actually use the range, not hover in the middle
    (is (< lo 0.01f0))
    (is (> hi 0.99f0))))

(test rnd01-is-a-pure-function
  "Same coordinates, same value — always, and regardless of anything
else that has happened in between."
  (dotimes (i 50)
    (let ((a (ant:rnd01 i (* i 7) (mod i 3))))
      (ant:rnd01 999 999 999)           ; noise in between
      (is (= a (ant:rnd01 i (* i 7) (mod i 3)))))))

(test rnd01-streams-are-independent
  "One ant needs several uncorrelated draws per tick — a turn angle and a
trail choice must not move together.  Independent uniforms differ by 1/3
on average; a shared or weakly mixed stream would show far less."
  (let ((n 20000) (sum 0.0d0) (same 0))
    (dotimes (id n)
      (let ((a (ant:rnd01 id 17 0))
            (b (ant:rnd01 id 17 1)))
        (incf sum (abs (- a b)))
        (when (= a b) (incf same))))
    (is (zerop same))
    (is (< (abs (- (/ sum n) 1/3)) 0.01d0))))

(test rnd01-neighbouring-ids-decorrelate
  "Ants are stepped by consecutive id on the same tick.  If neighbouring
ids gave similar values the colony would move in visible stripes."
  (let ((n 20000) (sum 0.0d0))
    (dotimes (id n)
      (incf sum (abs (- (ant:rnd01 id 5) (ant:rnd01 (1+ id) 5)))))
    (is (< (abs (- (/ sum n) 1/3)) 0.01d0))))

(test rnd01-successive-ticks-decorrelate
  "The same ant on successive ticks is the other axis of the same risk."
  (let ((n 20000) (sum 0.0d0))
    (dotimes (tick n)
      (incf sum (abs (- (ant:rnd01 42 tick) (ant:rnd01 42 (1+ tick))))))
    (is (< (abs (- (/ sum n) 1/3)) 0.01d0))))

(test rnd01-is-uniform
  "Chi-square over 16 bins.  The sequence is deterministic, so this is a
fixed number and not a flaky statistical test: 15 df, and anything past
about 38 would be a one-in-a-thousand event for a good generator."
  (let* ((bins (make-array 16 :initial-element 0))
         (n 160000))
    (dotimes (i n)
      (incf (aref bins (min 15 (floor (* 16 (ant:rnd01 i (floor i 97) 2)))))))
    (let* ((expected (/ n 16))
           (chi2 (loop for b across bins
                       sum (/ (expt (- b expected) 2) (float expected 1.0d0)))))
      (is (< chi2 38.0d0) "chi-square = ~,2f over bins ~a" chi2 bins))))

(test hash32-avalanches
  "About half the output bits should flip when one input bit does.  A
weak mixer here shows up as structure everywhere downstream."
  (let ((total 0) (n 0))
    (dotimes (i 256)
      (dotimes (bit 32)
        (let ((a (ant:hash32 i))
              (b (ant:hash32 (logxor i (ash 1 bit)))))
          (incf total (logcount (logxor a b)))
          (incf n))))
    (let ((mean (/ (float total 1.0d0) n)))
      (is (< (abs (- mean 16.0d0)) 0.5d0) "mean bit flips = ~,3f, want 16" mean))))

(test rnd01-seeds-are-independent
  "Replicates of one scenario differ only by seed, so two seeds must give
unrelated streams — otherwise §3.8's symmetry-breaking result would be
measuring one run reported N times."
  (let ((n 20000) (sum 0.0d0))
    (dotimes (id n)
      (incf sum (abs (- (ant:rnd01 id 3 0 1) (ant:rnd01 id 3 0 2)))))
    (is (< (abs (- (/ sum n) 1/3)) 0.01d0))))

(test rnd-u32-has-no-fixed-point-at-zero
  "Regression.  HASH32 fixes zero, so a single-round mix returned exactly
0 for (id 0, tick 0, stream 0) and RND01 returned 0.0 — the one value a
half-open uniform is most likely to be special-cased on.  Found while
pinning the constants below, and this is the guard against it coming
back."
  (is (/= 0 (ant:rnd-u32 0 0 0)))
  (is (/= 0.0f0 (ant:rnd01 0 0 0)))
  (let ((zeros 0))
    (dotimes (id 400)
      (dotimes (tick 400)
        (when (zerop (ant:rnd-u32 id tick)) (incf zeros))))
    ;; 160k draws from a 32-bit range: the expected count is 0.00004
    (is (zerop zeros) "~d of 160000 draws came out exactly zero" zeros)))

(test rnd-u32-pinned
  "Pin the exact numbers.  Stored runs and recorded acceptance results
are only meaningful if the stream cannot change silently — so changing
the mixing must break this test loudly and on purpose."
  (is (= 2337197272 (ant:rnd-u32 0 0 0)))
  (is (= 2395113101 (ant:rnd-u32 1 0 0)))
  (is (= 4140761879 (ant:rnd-u32 0 1 0)))
  (is (= 961406177  (ant:rnd-u32 0 0 1)))
  (is (= 2967891186 (ant:rnd-u32 0 0 0 7)))
  (is (= 3833443072 (ant:rnd-u32 12345 6789 3))))

;;; ------------------------------------------------------------- pool

(defmacro with-pool ((var n) &body body)
  `(let ((,var (ant:make-worker-pool ,n)))
     (unwind-protect (progn ,@body)
       (ant:pool-shutdown ,var))))

(test pool-covers-every-index-exactly-once
  (dolist (workers '(1 2 3 4 8))
    (dolist (total '(0 1 3 8 100 1000))
      (let ((hits (make-array (max total 1) :initial-element 0)))
        (with-pool (p workers)
          (ant:pool-run p total
                        (lambda (lo hi)
                          (loop for i from lo below hi
                                do (incf (aref hits i))))))
        (is (every (lambda (h) (= h 1)) (subseq hits 0 total))
            "workers=~d total=~d left ~a" workers total (subseq hits 0 total))))))

(test pool-tolerates-more-workers-than-work
  "Ranges are empty when total < worker count; the body must see lo = hi
rather than be skipped, and nothing may run off the end."
  (let ((hits (make-array 3 :initial-element 0))
        ;; a cons because ATOMIC-INCF works on CAR, not on a lexical
        (empties (cons 0 nil)))
    (with-pool (p 8)
      (ant:pool-run p 3
                    (lambda (lo hi)
                      (when (= lo hi) (sb-ext:atomic-incf (car empties)))
                      (loop for i from lo below hi do (incf (aref hits i))))))
    (is (every (lambda (h) (= h 1)) hits))
    ;; chunk = ceiling(3/8) = 1, so workers 0..2 get one index each and
    ;; workers 3..7 get [3,3)
    (is (= 5 (car empties)))))

(test pool-result-is-independent-of-worker-count
  "The whole reason for a fixed contiguous partition.  Anything computed
per index must come out bit-identical at every thread count."
  (let ((serial (make-array 5000 :element-type 'single-float)))
    (dotimes (i 5000)
      (setf (aref serial i) (ant:rnd01 i 3 1)))
    (dolist (workers '(1 2 3 7 16))
      (let ((out (ant:mkf32 5000)))
        (with-pool (p workers)
          (ant:pool-run p 5000
                        (lambda (lo hi)
                          (loop for i from lo below hi
                                do (setf (aref out i) (ant:rnd01 i 3 1))))))
        (is (equalp serial out) "worker count ~d changed the result" workers)))))

(test pool-run-is-a-barrier
  "POOL-RUN must not return before every worker has finished, or the
next phase of a tick reads half-written state."
  (with-pool (p 4)
    (let ((out (ant:mkfix 4000)))
      (dotimes (round 20)
        (ant:pool-run p 4000
                      (lambda (lo hi)
                        (loop for i from lo below hi
                              do (setf (aref out i) (+ i round)))))
        (is (loop for i from 0 below 4000 always (= (aref out i) (+ i round)))
            "round ~d observed unfinished work" round)))))

(test pool-is-reusable-across-many-runs
  (with-pool (p 4)
    (let ((sum 0))
      (dotimes (round 100)
        (let ((part (ant:mkfix 4 0)))
          (ant:pool-run p 400
                        (lambda (lo hi)
                          (loop for i from lo below hi
                                do (incf (aref part (floor lo 100)) i))))
          (incf sum (reduce #'+ part))))
      (is (= sum (* 100 (/ (* 399 400) 2)))))))
