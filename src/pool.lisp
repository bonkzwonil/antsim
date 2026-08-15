;;;; pool.lisp — persistent worker pool (README §4.5).
;;;;
;;;; Two rules, both of which exist to keep threaded runs bit-exact:
;;;;
;;;;   * Never `make-thread` per tick.  Workers are spawned once and park
;;;;     on semaphores; a tick costs a signal and a barrier wait.
;;;;   * The partition is a pure function of (total, worker count).  Worker
;;;;     k always gets the same contiguous [lo, hi) for a given total, so
;;;;     no result depends on which thread got there first.  Work stealing
;;;;     would be faster and would destroy reproducibility, which is not a
;;;;     trade this project is willing to make (§4.4).
;;;;
;;;; Determinism needs one more thing that this file cannot enforce: the
;;;; body must not have cross-range data dependencies.  That is why the
;;;; tick reads the previous state and writes into separate buffers —
;;;; the Jacobi collision pass in §3.11 is the load-bearing example.
;;;;
;;;; Carried over from waldameisen, where the same structure was measured
;;;; bit-identical across thread counts.

(in-package #:antsim)

(defstruct (pool (:constructor %make-pool))
  (n 0 :type fixnum)
  (threads nil :type list)
  (go-sems nil :type list)
  (done (sb-thread:make-semaphore) :type sb-thread:semaphore)
  (fn nil :type (or null function))
  (los nil :type (or null fixv))
  (his nil :type (or null fixv))
  (stop nil))

(defun make-worker-pool (n)
  "Spawn N persistent workers, parked on semaphores."
  (declare (type fixnum n))
  (assert (plusp n) (n) "A worker pool needs at least one worker, got ~a." n)
  (let* ((p (%make-pool :n n :los (mkfix n) :his (mkfix n)))
         (sems (loop repeat n collect (sb-thread:make-semaphore))))
    (setf (pool-go-sems p) sems)
    (setf (pool-threads p)
          (loop for k from 0 below n
                for sem in sems
                collect (let ((k k) (sem sem))
                          (sb-thread:make-thread
                           (lambda ()
                             (loop
                               (sb-thread:wait-on-semaphore sem)
                               (when (pool-stop p) (return))
                               (funcall (the function (pool-fn p))
                                        (aref (pool-los p) k) (aref (pool-his p) k))
                               (sb-thread:signal-semaphore (pool-done p))))
                           :name (format nil "antsim-worker-~d" k)))))
    p))

(defun pool-run (p total fn)
  "Run FN over [0, TOTAL) split into fixed contiguous ranges, one per
worker.  FN is called as (fn lo hi) and must confine its writes to that
range.  Blocks until every worker has finished — one barrier per call.

Ranges may be empty when TOTAL is smaller than the worker count; FN must
tolerate lo = hi rather than assume it has work."
  (declare (type pool p) (type fixnum total) (type function fn))
  (let* ((n (pool-n p)) (chunk (ceiling total n)))
    (declare (type fixnum n chunk))
    (setf (pool-fn p) fn)
    (dotimes (k n)
      (setf (aref (pool-los p) k) (min total (* k chunk))
            (aref (pool-his p) k) (min total (* (1+ k) chunk))))
    (dolist (s (pool-go-sems p)) (sb-thread:signal-semaphore s))
    (sb-thread:wait-on-semaphore (pool-done p) :n n))
  (values))

(defun pool-shutdown (p)
  "Stop the workers and join them.  The pool is unusable afterwards."
  (declare (type pool p))
  (setf (pool-stop p) t)
  (dolist (s (pool-go-sems p)) (sb-thread:signal-semaphore s))
  (mapc #'sb-thread:join-thread (pool-threads p))
  (setf (pool-threads p) nil)
  (values))
